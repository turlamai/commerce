#lang racket/base

;; This database is separately provisioned and is not a payment journal.
;; Loss or an inconsistent restore requires operator reconciliation.
(provide initialize-sqlite-alipay-checkout-claims!
         make-sqlite-alipay-checkout-claimer)

(require db)

(define (with-db path mode proc)
  (define db (sqlite3-connect #:database path #:mode mode
                              #:busy-retry-delay 0.05 #:busy-retry-limit 100))
  (dynamic-wind void (lambda () (proc db)) (lambda () (disconnect db))))

(define (initialize-sqlite-alipay-checkout-claims! path)
  (unless (path-string? path) (raise-argument-error 'initialize-sqlite-alipay-checkout-claims! "path-string?" path))
  (with-db path 'create
    (lambda (db)
      (query-exec db "CREATE TABLE IF NOT EXISTS alipay_checkout_claim
                      (order_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)")
      (query-exec db "CREATE TRIGGER IF NOT EXISTS alipay_claim_no_update BEFORE UPDATE ON alipay_checkout_claim BEGIN SELECT RAISE(ABORT, 'immutable checkout claim'); END")
      (query-exec db "CREATE TRIGGER IF NOT EXISTS alipay_claim_no_delete BEFORE DELETE ON alipay_checkout_claim BEGIN SELECT RAISE(ABORT, 'immutable checkout claim'); END")))
  (void))

(define (make-sqlite-alipay-checkout-claimer path)
  (unless (path-string? path) (raise-argument-error 'make-sqlite-alipay-checkout-claimer "path-string?" path))
  (with-db path 'read/write
    (lambda (db)
      (unless (= 1 (query-value db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='alipay_checkout_claim'"))
        (error 'make-sqlite-alipay-checkout-claimer "checkout claims not provisioned"))))
  (lambda (order fingerprint binding-exists?)
    (unless (and (string? order) (regexp-match? #px"^ali[0-9a-f]{32}$" order)
                 (string? fingerprint) (regexp-match? #px"^[0-9a-f]{64}$" fingerprint)
                 (boolean? binding-exists?))
      (error 'alipay-checkout-claim "invalid claim"))
    (with-db path 'read/write
      (lambda (db)
        (call-with-transaction db
          (lambda ()
            (define existing (query-maybe-value db "SELECT fingerprint FROM alipay_checkout_claim WHERE order_id=?" order))
            (cond [existing (and (equal? existing fingerprint) #t)]
                  [binding-exists? #f]
                  [else
                   (query-exec db "INSERT INTO alipay_checkout_claim(order_id, fingerprint) VALUES (?, ?)" order fingerprint)
                   #t]))
          #:option 'immediate)))))
