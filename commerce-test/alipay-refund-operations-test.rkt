#lang racket/base

(require rackunit
         racket/file
         json
         base64
         file/sha1
         crypto
         crypto/libcrypto
         commerce
         commerce/alipay
         commerce/alipay/refund-operations
         commerce/provider
         commerce/journal
         commerce/storage
         commerce/storage/sqlite)

;; All proof bytes and keys are generated in memory; NO real merchant refund.
(define-values (key public)
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (define private-key (generate-private-key (get-pk 'rsa) '((nbits 2048))))
    (define pem
      (string-append
       "-----BEGIN PUBLIC KEY-----\n"
       (bytes->string/utf-8
        (base64-encode
         (pk-key->datum (pk-key->public-only-key private-key)
                        'SubjectPublicKeyInfo)
         #:line #f))
       "\n-----END PUBLIC KEY-----\n"))
    (values private-key pem)))

(define binding
  (alipay-binding "fixture-app" "fixture-seller" "fixture-order"
                  "taskly-pro-lifetime" "account-a" (money "CNY" 1234)))

(define (refund-query)
  (define raw
    (jsexpr->string
     (hasheq 'code "10000"
             'refund_status "REFUND_SUCCESS"
             'out_trade_no "fixture-order"
             'trade_no "202610301234567890"
             'out_request_no "refund-001"
             'refund_amount "12.34"
             'gmt_refund_pay "2026-10-30 13:45:00")))
  (define signature
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign key 'sha256 (string->bytes/utf-8 raw)
                   #:pad 'pkcs1-v1.5)))
  (string->bytes/utf-8
   (string-append
    "{\"alipay_trade_fastpay_refund_query_response\":"
    raw ",\"sign\":\""
    (bytes->string/utf-8 (base64-encode signature #:line #f))
    "\"}")))

(define (allow op value id)
  (and (equal? op "operator-a")
       (equal? (alipay-binding-order-id value) "fixture-order")
       (equal? id "refund-001")))

(define (failed-with? code thunk)
  (check-exn
   (lambda (e)
     (and (exn:fail:commerce? e)
          (eq? (exn:fail:commerce-code e) code)))
   thunk))

(define (with-paid-order proc)
  (define dir (make-temporary-file "commerce-refund-lifecycle-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage (open-sqlite-commerce-storage
                      (build-path dir "commerce.sqlite")))
     (define refund-db (build-path dir "refund.sqlite"))
     (initialize-sqlite-alipay-refund-operations! refund-db)
     (dynamic-wind
      void
      (lambda ()
        (storage-create-checkout-binding!
         storage
         (checkout-binding "fixture-order" "alipay"
                           "taskly" "taskly-pro-lifetime" "account-a"
                           "CNY" 1234 2)
         #:created-at 1)
        (define raw #"synthetic-payment-evidence")
        (define paid
          (make-verified-payment-event
           "alipay" "notification-001" (bytes->hex-string (sha256-bytes raw))
           'payment-succeeded "fixture-order" "taskly-pro-lifetime"
           "account-a" (money "CNY" 1234) 1793334600))
        (journal-accept! storage raw paid #:received-at 2)
        (storage-project-next! storage #:processed-at 3)
        (proc storage refund-db))
      (lambda () (storage-close storage))))
   (lambda () (delete-directory/files dir))))

(define (request db storage
                 #:id [id "refund-001"]
                 #:operator [operator "operator-a"]
                 #:allow [permission allow])
  (request-alipay-full-refund!
   db storage binding id
   #:environment 'sandbox #:operator operator
   #:authorize permission #:at 1793692800))

(define (send db storage send-once)
  (dispatch-alipay-full-refund-once!
   db storage binding "refund-001"
   #:environment 'sandbox #:operator "operator-a"
   #:authorize allow #:send-once send-once #:at 1793692801))

(define (reconcile db storage query)
  (reconcile-alipay-full-refund!
   db storage binding "refund-001"
   #:environment 'sandbox #:operator "operator-a"
   #:authorize allow #:alipay-public-key public
   #:signed-query query #:at 1793692802))

(test-case "unknown provider outcome can never automatically send twice"
  (with-paid-order
   (lambda (storage db)
     (check-eq? (alipay-full-refund-operation-status db "refund-001") 'absent)
     (check-eq? (request db storage) 'requested)
     (check-eq? (request db storage) 'requested)
     (define count 0)
     (check-eq?
      (send db storage
            (lambda (_binding request-id amount environment)
              (set! count (add1 count))
              (check-equal? request-id "refund-001")
              (check-equal? amount 1234)
              (check-eq? environment 'sandbox)
              (error 'mock-network "timeout after remote may have charged")))
      'unknown)
     (check-equal? count 1)
     (check-eq? (alipay-full-refund-operation-status db "refund-001") 'unknown)
     (failed-with?
      'alipay-refund-repeat-dispatch
      (lambda () (send db storage
                       (lambda _ (set! count (add1 count))))))
     (check-equal? count 1)
     (check-eq?
      (reconcile db storage (lambda (_binding _id) (refund-query)))
      'confirmed)
     (check-eq? (alipay-full-refund-operation-status db "refund-001") 'confirmed)
     (check-eq? (reconcile db storage
                            (lambda _ (error 'never "should not re-query")))
                'confirmed)
     (check-true (journal-record? (journal-ref storage "alipay"
                                              "refund:refund-001")))
     (storage-project-next! storage #:processed-at 1793692803)
     (check-true (order-projection-refunded?
                  (storage-order-ref storage "alipay" "fixture-order")))
     (failed-with?
      'alipay-refund-repeat-dispatch
      (lambda () (send db storage (lambda _ (void))))))))

(test-case "unauthorized, second request ID or forged query cannot withdraw"
  (with-paid-order
   (lambda (storage db)
     (failed-with?
      'alipay-refund-unauthorized
      (lambda ()
        (request db storage #:operator "another-operator")))
     (check-eq? (request db storage) 'requested)
     (failed-with?
      'alipay-refund-conflict
      (lambda ()
        (request db storage #:id "refund-002"
                 #:allow (lambda (_op _binding _id) #t))))
     ;; No remote request until the operator explicitly authorizes dispatch.
     (failed-with?
      'alipay-refund-not-dispatched
      (lambda () (reconcile db storage
                            (lambda (_binding _id) (refund-query)))))
     (check-eq? (send db storage (lambda _ (values 200 #"success"))) 'unknown)
     (check-exn exn:fail?
                (lambda () (reconcile db storage
                                      (lambda (_binding _id) #"unsigned"))))
     (check-eq? (alipay-full-refund-operation-status db "refund-001") 'unknown)
     (check-false (journal-ref storage "alipay" "refund:refund-001")))))

(test-case "missing refund ledger refuses rather than silently resetting retry state"
  (with-paid-order
   (lambda (storage db)
     (request db storage)
     (send db storage (lambda _ (void)))
     (delete-file db)
     (check-exn exn:fail?
                (lambda () (alipay-full-refund-operation-status
                            db "refund-001")))
     (check-exn exn:fail?
                (lambda ()
                  (send db storage (lambda _ (error 'unexpected "sent"))))))))
