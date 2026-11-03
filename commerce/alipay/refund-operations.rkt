#lang racket/base

;; A durable operator-only Alipay full-refund lifecycle. Unknown outcomes are
;; never automatically re-sent: the same out_request_no is reconciled using
;; a separately verified, signed refund query before any rights withdrawal.
;; This module does NOT open an HTTP endpoint or schedule money-moving work.
(provide initialize-sqlite-alipay-refund-operations!
         request-alipay-full-refund!
         dispatch-alipay-full-refund-once!
         reconcile-alipay-full-refund!
         alipay-full-refund-operation-status)

(require db
         "../alipay.rkt"
         "refund.rkt"
         "../storage.rkt"
         "../private/model.rkt")

(define (refuse code)
  (raise (exn:fail:commerce "Alipay refund operation refused"
                            (current-continuation-marks) code (hash))))

(define (request-id? value)
  (and (string? value)
       (regexp-match? #px"^[A-Za-z0-9_-]{1,64}$" value)))

(define (operator-id? value)
  (and (string? value) (<= 1 (string-length value) 128)
       (regexp-match? #px"^[A-Za-z0-9_-]+$" value)))

(define (check-fields path binding request-id operator environment at)
  (unless (and (path-string? path)
               (alipay-binding? binding)
               (request-id? request-id)
               (operator-id? operator)
               (member environment '(sandbox production))
               (exact-nonnegative-integer? at))
    (refuse 'alipay-refund-request-invalid)))

(define (connection path mode)
  (sqlite3-connect #:database path #:mode mode
                   #:busy-retry-delay 0.05 #:busy-retry-limit 40))

(define (with-db path proc #:mode [mode 'read/write])
  (define db (connection path mode))
  (dynamic-wind void (lambda () (proc db))
                (lambda () (disconnect db))))

(define (initialize-sqlite-alipay-refund-operations! path)
  (unless (path-string? path)
    (raise-argument-error 'initialize-sqlite-alipay-refund-operations!
                          "path-string?" path))
  ;; Provisioning must be explicit. Runtime reads use read/write, which
  ;; refuses to silently create an empty DB after a crash or lost file.
  (with-db
   path
   (lambda (db)
     (query-exec db
      "CREATE TABLE IF NOT EXISTS alipay_refund_operation (
         request_id TEXT PRIMARY KEY NOT NULL,
         environment TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
         app_id TEXT NOT NULL,
         seller_id TEXT NOT NULL,
         order_id TEXT NOT NULL,
         amount_fen INTEGER NOT NULL CHECK(amount_fen > 0),
         operator_id TEXT NOT NULL,
         authorized_at INTEGER NOT NULL CHECK(authorized_at >= 0),
         status TEXT NOT NULL CHECK(status IN ('requested','unknown','confirmed')),
         updated_at INTEGER NOT NULL CHECK(updated_at >= 0),
         UNIQUE(environment, app_id, order_id)
       )")
     (query-exec db
      "CREATE TRIGGER IF NOT EXISTS alipay_refund_identity_immutable
       BEFORE UPDATE OF request_id, environment, app_id, seller_id, order_id,
                        amount_fen, operator_id, authorized_at
       ON alipay_refund_operation
       BEGIN SELECT RAISE(ABORT, 'immutable refund identity'); END"))
   #:mode 'create)
  (void))

(define (same-request? row binding request-id operator environment)
  (and row
       (equal? (vector-ref row 0) request-id)
       (equal? (vector-ref row 1) (symbol->string environment))
       (equal? (vector-ref row 2) (alipay-binding-app-id binding))
       (equal? (vector-ref row 3) (alipay-binding-seller-id binding))
       (equal? (vector-ref row 4) (alipay-binding-order-id binding))
       (= (vector-ref row 5)
          (money-minor-units (alipay-binding-amount binding)))
       (equal? (vector-ref row 6) operator)))

(define (find-operation db request-id)
  (query-maybe-row
   db
   "SELECT request_id, environment, app_id, seller_id, order_id,
           amount_fen, operator_id, status
    FROM alipay_refund_operation WHERE request_id = ?" request-id))

(define (verify-original-order storage binding)
  (unless (commerce-storage? storage)
    (raise-argument-error 'verify-original-order "commerce-storage?" storage))
  (define id (alipay-binding-order-id binding))
  (define expected (alipay-binding-amount binding))
  (define persisted (storage-checkout-binding-ref storage id))
  (define order (storage-order-ref storage "alipay" id))
  (unless (and persisted
               (equal? (checkout-binding-provider persisted) "alipay")
               (equal? (checkout-binding-merchant-external-id persisted) id)
               (equal? (checkout-binding-offer-id persisted)
                       (alipay-binding-offer-id binding))
               (equal? (checkout-binding-subject-id persisted)
                       (alipay-binding-subject-id binding))
               (equal? (checkout-binding-currency persisted) "CNY")
               (= (checkout-binding-amount-minor-units persisted)
                  (money-minor-units expected))
               order
               (order-projection-paid? order)
               (not (order-projection-refunded? order))
               (equal? (order-projection-offer-id order)
                       (alipay-binding-offer-id binding))
               (equal? (order-projection-subject-id order)
                       (alipay-binding-subject-id binding))
               (equal? (order-projection-amount order) expected))
    (refuse 'alipay-refund-order-unpaid)))

(define (allow-operator? allow operator binding request-id)
  (and (procedure? allow)
       (procedure-arity-includes? allow 3)
       (eq? #t (allow operator binding request-id))))

(define (request-alipay-full-refund! path storage binding request-id
                                    #:environment environment
                                    #:operator operator #:authorize allow
                                    #:at [at (current-seconds)])
  (check-fields path binding request-id operator environment at)
  (unless (allow-operator? allow operator binding request-id)
    (refuse 'alipay-refund-unauthorized))
  (verify-original-order storage binding)
  (with-db
   path
   (lambda (db)
     (call-with-transaction
      db
      (lambda ()
        (query-exec
         db
         "INSERT OR IGNORE INTO alipay_refund_operation
          (request_id, environment, app_id, seller_id, order_id,
           amount_fen, operator_id, authorized_at, status, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'requested', ?)"
         request-id (symbol->string environment)
         (alipay-binding-app-id binding)
         (alipay-binding-seller-id binding)
         (alipay-binding-order-id binding)
         (money-minor-units (alipay-binding-amount binding))
         operator at at)
        ;; A different request ID for the same merchant order is forbidden;
        ;; it cannot evade the order-level uniqueness gate.
        (define row
          (query-maybe-row
           db
           "SELECT request_id, environment, app_id, seller_id, order_id,
                   amount_fen, operator_id, status
            FROM alipay_refund_operation
            WHERE environment=? AND app_id=? AND order_id=?"
           (symbol->string environment)
           (alipay-binding-app-id binding)
           (alipay-binding-order-id binding)))
        (unless (same-request? row binding request-id operator environment)
          (refuse 'alipay-refund-conflict))
        (string->symbol (vector-ref row 7)))
      #:option 'immediate))))

(define (alipay-full-refund-operation-status path request-id)
  (unless (and (path-string? path) (request-id? request-id))
    (refuse 'alipay-refund-request-invalid))
  (with-db
   path
   (lambda (db)
     (define row (find-operation db request-id))
     (if row (string->symbol (vector-ref row 7)) 'absent))))

(define (dispatch-alipay-full-refund-once! path storage binding request-id
                                           #:environment environment
                                           #:operator operator
                                           #:authorize allow
                                           #:send-once send-once
                                           #:at [at (current-seconds)])
  (check-fields path binding request-id operator environment at)
  (unless (and (allow-operator? allow operator binding request-id)
               (procedure? send-once)
               (procedure-arity-includes? send-once 4))
    (refuse 'alipay-refund-unauthorized))
  (verify-original-order storage binding)
  (with-db
   path
   (lambda (db)
     (call-with-transaction
      db
      (lambda ()
        (define row (find-operation db request-id))
        (unless (and (same-request? row binding request-id operator environment)
                     (equal? (vector-ref row 7) "requested"))
          (refuse 'alipay-refund-repeat-dispatch))
        ;; Durable intent is now UNKNOWN *before* touching the provider.
        ;; A crash here cannot cause an automatic second remote request.
        (query-exec db
                    "UPDATE alipay_refund_operation
                     SET status='unknown', updated_at=?
                     WHERE request_id=? AND status='requested'"
                    at request-id)
        (unless (= 1 (query-value db "SELECT changes()"))
          (refuse 'alipay-refund-repeat-dispatch)))
      #:option 'immediate)))
  ;; Deliberately no implicit retry, and no HTTP 2xx/Alipay code=10000
  ;; can transition to 'confirmed'. A signed independent query must do so.
  (with-handlers ([exn:fail? (lambda (_) 'unknown)])
    (send-once binding request-id
               (money-minor-units (alipay-binding-amount binding))
               environment)
    'unknown))

(define (reconcile-alipay-full-refund! path storage binding request-id
                                       #:environment environment
                                       #:operator operator #:authorize allow
                                       #:alipay-public-key public-key
                                       #:signed-query signed-query
                                       #:at [at (current-seconds)])
  (check-fields path binding request-id operator environment at)
  (unless (and (allow-operator? allow operator binding request-id)
               (string? public-key)
               (procedure? signed-query)
               (procedure-arity-includes? signed-query 2))
    (refuse 'alipay-refund-unauthorized))
  (define state
    (with-db
     path
     (lambda (db)
       (define row (find-operation db request-id))
       (unless (same-request? row binding request-id operator environment)
         (refuse 'alipay-refund-conflict))
       (string->symbol (vector-ref row 7)))))
  (cond
    [(eq? state 'confirmed) 'confirmed]
    [(not (eq? state 'unknown)) (refuse 'alipay-refund-not-dispatched)]
    [else
     ;; Signed provider query -> independently verified canonical journal ->
     ;; durable operation completion. A crash after journal acceptance is
     ;; harmless: replay uses the same refund event key and bytes.
     (define raw (signed-query binding request-id))
     (journal-alipay-full-refund! storage raw public-key binding request-id
                                 #:received-at at)
     (with-db
      path
      (lambda (db)
        (call-with-transaction
         db
         (lambda ()
           (query-exec
            db
            "UPDATE alipay_refund_operation
             SET status='confirmed', updated_at=?
             WHERE request_id=? AND status='unknown'"
            at request-id)
           (unless (= 1 (query-value db "SELECT changes()"))
             (unless (equal?
                      (query-maybe-value
                       db "SELECT status FROM alipay_refund_operation
                           WHERE request_id=?" request-id)
                      "confirmed")
               (refuse 'alipay-refund-conflict))))
         #:option 'immediate)))
     'confirmed]))
