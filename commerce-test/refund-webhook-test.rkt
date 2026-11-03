#lang racket/base

;; Issue #40: Pancake refund.succeeded ingestion and issuer re-verification.
;; A signed refund webhook journals a full refund against the durable
;; binding and paid projection; the issuer re-verifies the stored bytes
;; offline before withdrawing. Partial refunds, failed refunds, forged
;; bytes, unknown orders, and subject redirects all fail closed.

(require base64
         commerce
         commerce/evidence
         commerce/issuer
         commerce/journal
         commerce/pancake
         commerce/permit
         commerce/provider
         commerce/server
         commerce/storage
         commerce/storage/sqlite
         crypto
         crypto/libcrypto
         db
         json
         net/url
         permit/envelope
         permit/issuer
         rackunit
         racket/file
         racket/list
         web-server/http)

(parameterize ([crypto-factories (list libcrypto-factory)])
  (crypto-factories))

;; ---- fixture key material ------------------------------------------------

(define webhook-private-key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))

(define (pem label datum)
  (define encoded
    (bytes->string/utf-8
     (base64-encode datum #:line #f)))
  (string-append
   "-----BEGIN " label "-----\n"
   encoded
   "\n-----END " label "-----\n"))

(define webhook-keyring
  (pancake-webhook-keyring
   (pem "PUBLIC KEY"
        (pk-key->datum
         (pk-key->public-only-key webhook-private-key)
         'SubjectPublicKeyInfo))
   (pem "PUBLIC KEY"
        (pk-key->datum
         (pk-key->public-only-key
          (parameterize ([crypto-factories (list libcrypto-factory)])
            (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
         'SubjectPublicKeyInfo))))

(define-values (permit-private-key permit-public-key)
  (generate-ed25519-keypair))

(define issuer-name "com.turinglambdaai")
(define key-id "test-2026")

(define trust-store
  (jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1
           'issuer issuer-name
           'keys
           (hasheq 'test-2026
                   (hasheq 'algorithm "Ed25519"
                           'public_key (public-key->base64 permit-public-key)
                           'status "active"
                           'purposes '("entitlement")
                           'not_before 'null
                           'not_after 'null)))))

(define catalog
  (make-permit-policy-catalog
   (list (offer "taskly-pro-lifetime" "taskly" 'one-time
                (money "CNY" 2900) "taskly-pro-v1"))
   (list (make-permit-entitlement-policy
          "taskly-pro-v1" 1
          #:subject-type 'person
          #:grants (list (make-permit-grant-policy
                          #:products '("taskly") #:edition "pro"))))))

;; ---- webhook bodies ------------------------------------------------------

(define (signed-webhook body
                         #:event-id-override [event-id-override #f])
  (define now-ms
    (inexact->exact (floor (current-inexact-milliseconds))))
  (define final-body
    (if event-id-override
        (jsexpr->bytes
         (hash-set (bytes->jsexpr body) 'eventId event-id-override))
        body))
  (define signature
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign webhook-private-key 'sha256
                   (bytes-append
                    (string->bytes/utf-8
                     (string-append (number->string now-ms) "."))
                    final-body)
                   #:pad 'pkcs1-v1.5)))
  (values final-body
          (string-append
           "t=" (number->string now-ms)
           ",v1="
           (bytes->string/utf-8 (base64-encode signature #:line #f)))))

(define (payment-body)
  (jsexpr->bytes
   (hash 'id "PAY_rw_001"
         'timestamp "2026-11-03T00:00:00.000Z"
         'eventType "order.completed"
         'eventId "PAY_rw_001"
         'storeId "STO_rw_001"
         'storeName "Refund Store"
         'mode "test"
         'data (hash 'orderId "ORD_rw_001"
                     'chargedAmount "29.00"
                     'currency "CNY"
                     'paymentId "PAY_rw_001"
                     'paymentStatus "succeeded"))))

(define (refund-body
         #:event-id [event-id "REF_rw_001"]
         #:refunded [refunded "29.00"]
         #:charged [charged "29.00"]
         #:status [status "succeeded"]
         #:created-at [created-at "2026-11-03T08:00:00.000Z"])
  (jsexpr->bytes
   (hash 'id event-id
         'timestamp "2026-11-03T08:00:00.000Z"
         'eventType "refund.succeeded"
         'eventId event-id
         'storeId "STO_rw_001"
         'storeName "Refund Store"
         'mode "test"
         'data (hash 'orderId "ORD_rw_001"
                     'orderStatus "completed"
                     'currency "CNY"
                     'refundedAmount refunded
                     'amount refunded
                     'originalChargedAmount charged
                     'paymentId "PAY_rw_001"
                     'refundStatus status
                     'refundTicketMerchantExternalId "REF-2026-00091"
                     'refundCreatedAt created-at))))

(define binding-row
  (checkout-binding "ORD_rw_001" "pancake" "PROD_rw_001"
                    "taskly-pro-lifetime" "customer-002" "CNY" 2900 2))

;; ---- fixtures ------------------------------------------------------------

(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-pancake-refund-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (rfc3339-for epoch-seconds)
  (define moment (seconds->date epoch-seconds #t))
  (define (pad2 value)
    (if (< value 10) (string-append "0" (number->string value))
        (number->string value)))
  (string-append
   (number->string (date-year moment))
   "-" (pad2 (date-month moment))
   "-" (pad2 (date-day moment))
   "T" (pad2 (date-hour moment))
   ":" (pad2 (date-minute moment))
   ":" (pad2 (date-second moment)) "Z"))

(define (clock-at epoch-seconds)
  (lambda () (values epoch-seconds (rfc3339-for epoch-seconds))))

;; Payment webhook ingestion needs the merchant-client active-order query;
;; the transport is mocked to return a completed paid order.
(define merchant-client
  (make-pancake-merchant-client
   "MER_rw001"
   (pem "PRIVATE KEY"
        (pk-key->datum webhook-private-key 'OneAsymmetricKey))
   #:environment 'test
   #:clock (lambda () 1792108800)
   #:transport
   (lambda (endpoint headers body connect-timeout request-timeout)
     (values 200
             (jsexpr->bytes
              (hash 'data
                    (hash 'onetimeOrder
                          (hash 'id "ORD_rw_001"
                                'status "completed"
                                'testMode #t
                                'currency "CNY"
                                'orderMerchantExternalId "ORD_rw_001"
                                'store (hash 'id "STO_rw_001")
                                'onetimeProduct (hash 'id "PROD_rw_001")
                                'payments
                                (list
                                 (hash 'id "PAY_rw_001"
                                       'status "succeeded"
                                       'snapshotAmountDetails
                                       (hash 'currency "CNY" 'total "29.00")))))))))))

;; Opens storage, seeds the binding, journals the paid payment through the
;; real webhook handler, projects it, and returns the endpoint for refunds.
(define (call-with-paid-endpoint proc)
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-sqlite-commerce-storage path))
     (storage-create-checkout-binding! storage binding-row
                                       #:created-at 1)
     (define endpoint
       (make-webhook-endpoint
        #:keyring webhook-keyring
        #:environment 'test
        #:merchant-client merchant-client
        #:binding-lookup
        (lambda (order-id)
          (storage-checkout-binding-ref storage order-id))
        #:storage storage))
     (define-values (pay-body pay-header) (signed-webhook (payment-body)))
     (define-values (status payload)
       (handle-webhook-post endpoint pay-body pay-header))
     (check-eq? status 200)
     (check-equal? (hash-ref (bytes->jsexpr payload) 'disposition)
                   "accepted")
     (check-eq?
      (projection-result-disposition
       (storage-project-next! storage #:processed-at 11))
      'projected)
     (proc storage endpoint path))))

(define (make-verifier storage)
  (make-issuance-evidence-verifier
   #:catalog catalog
   #:pancake-keyring webhook-keyring
   #:binding-lookup
   (lambda (order-id)
     (storage-checkout-binding-ref storage order-id))))

(define (make-worker storage)
  (make-issuance-worker
   #:catalog catalog
   #:issuer issuer-name
   #:private-key permit-private-key
   #:key-id key-id
   #:trust-store trust-store
   #:clock (clock-at 100)
   #:evidence-verifier (make-verifier storage)))

(define (journal-count storage)
  (length (storage-order-journal storage "pancake" "ORD_rw_001")))

;; ---- tests ---------------------------------------------------------------

(test-case "a signed full refund withdraws through re-verification"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     (define-values (refund-payload refund-header)
       (signed-webhook (refund-body)))
     (define-values (status body)
       (handle-webhook-post endpoint refund-payload refund-header))
     (check-eq? status 200)
     (check-equal? (hash-ref (bytes->jsexpr body) 'disposition) "accepted")
     ;; Exact redelivery replays without a second row.
     (define-values (retry-status retry-body)
       (handle-webhook-post endpoint refund-payload refund-header))
     (check-eq? retry-status 200)
     (check-equal? (hash-ref (bytes->jsexpr retry-body) 'disposition)
                   "replayed")
     (check-equal? (journal-count storage) 2)
     (check-eq?
      (projection-result-disposition
       (storage-project-next! storage #:processed-at 21))
      'projected)
     (define worker (make-worker storage))
     (define grant (process-issuance-work! worker storage))
     (check-eq? (issuance-result-disposition grant) 'completed)
     (define withdrawal (process-issuance-work! worker storage))
     (check-eq? (issuance-result-disposition withdrawal) 'completed)
     (define connection (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_entitlement_revision")
      2)
     (disconnect connection)
     (storage-close storage))))

(test-case "a partial refund is refused durably and journals nothing"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     (define-values (refund-payload refund-header)
       (signed-webhook (refund-body #:refunded "10.00")))
     (define-values (status body)
       (handle-webhook-post endpoint refund-payload refund-header))
     (check-eq? status 422)
     (check-false (hash-ref (bytes->jsexpr body) 'accepted))
     (check-equal? (journal-count storage) 1)
     (storage-close storage))))

(test-case "a failed refund moves no journal row"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     (define-values (refund-payload refund-header)
       (signed-webhook (refund-body #:status "failed")))
     (define-values (status body)
       (handle-webhook-post endpoint refund-payload refund-header))
     (check-eq? status 422)
     (check-equal? (journal-count storage) 1)
     (storage-close storage))))

(test-case "forged refund bytes never journal"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     (define-values (refund-payload refund-header)
       (signed-webhook (refund-body)))
     (define-values (status body)
       (handle-webhook-post endpoint
                            (bytes-append refund-payload #" ")
                            refund-header))
     (check-eq? status 401)
     (check-equal? (journal-count storage) 1)
     (storage-close storage))))

(test-case "a refund for an unknown order is a durable 404"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     (define unknown
       (jsexpr->bytes
        (hash-set (bytes->jsexpr (refund-body) )
                  'data
                  (hash 'orderId "ORD_unknown"
                        'currency "CNY"
                        'refundedAmount "29.00"
                        'amount "29.00"
                        'originalChargedAmount "29.00"
                        'refundStatus "succeeded"
                        'refundTicketMerchantExternalId "REF-2026-00092"
                        'refundCreatedAt "2026-11-03T08:00:00.000Z"))))
     (define-values (refund-payload refund-header) (signed-webhook unknown))
     (define-values (status body)
       (handle-webhook-post endpoint refund-payload refund-header))
     (check-eq? status 404)
     (check-equal? (hash-ref (bytes->jsexpr body) 'error) "unknown-checkout")
     (check-equal? (journal-count storage) 1)
     (storage-close storage))))

(test-case "an unsupported signed event type is refused"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     (define other
       (jsexpr->bytes
        (hash-set (bytes->jsexpr (refund-body))
                  'eventType "subscription.renewed")))
     (define-values (refund-payload refund-header) (signed-webhook other))
     (define-values (status body)
       (handle-webhook-post endpoint refund-payload refund-header))
     (check-eq? status 422)
     (check-equal? (journal-count storage) 1)
     (storage-close storage))))

(test-case "a refund row without evidence fails closed at the issuer"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     ;; Journal a refund row through the storage API directly, without the
     ;; signature evidence envelope, simulating a writer that skipped the
     ;; edge discipline. The issuer must refuse the withdrawal.
     (define refund-raw (refund-body #:event-id "REF_rw_no_ev"))
     (journal-accept!
      storage refund-raw
      (make-verified-payment-event
       "pancake" "REF_rw_no_ev"
       (bytes->hex-string
        (parameterize ([crypto-factories (list libcrypto-factory)])
          (digest 'sha256 refund-raw)))
       'payment-refunded "ORD_rw_001"
       "taskly-pro-lifetime" "customer-002" (money "CNY" 2900)
       1793462400)
      #:received-at 20)
     (storage-project-next! storage #:processed-at 21)
     (define worker (make-worker storage))
     (check-eq?
      (issuance-result-disposition (process-issuance-work! worker storage))
      'completed)
     (define withdrawal
       (process-issuance-work! worker storage))
     (check-eq? (issuance-result-disposition withdrawal) 'released)
     (check-equal? (issuance-result-error-code withdrawal)
                   'evidence-unverifiable)
     (storage-close storage))))

(test-case "a refund redirected to another subject hits the binding fence"
  (call-with-paid-endpoint
   (lambda (storage endpoint path)
     ;; Genuine signed refund bytes and a genuine evidence header, but the
     ;; journaled event names a different subject: exactly what a fully
     ;; compromised edge could write. The projector itself blocks the subject
     ;; swap, so the hostile writer also rewrites the order projection; the
     ;; issuer's binding fence must still be the wall.
     (define-values (refund-raw refund-header)
       (signed-webhook (refund-body #:event-id "REF_rw_ev_9")))
     (journal-accept!
      storage refund-raw
      (make-verified-payment-event
       "pancake" "REF_rw_ev_9"
       (bytes->hex-string
        (parameterize ([crypto-factories (list libcrypto-factory)])
          (digest 'sha256 refund-raw)))
       'payment-refunded "ORD_rw_001"
       "taskly-pro-lifetime" "customer-999" (money "CNY" 2900)
       1793462400)
      #:received-at 20
      #:evidence (jsexpr->bytes
                  (hasheq 'environment "test"
                          'signature_header refund-header)))
     (define connection (sqlite3-connect #:database path))
     (query-exec connection
                 "UPDATE commerce_order_projection SET subject_id = 'customer-999'")
     (disconnect connection)
     (check-eq?
      (projection-result-disposition
       (storage-project-next! storage #:processed-at 21))
      'projected)
     ;; First pending row: the genuine grant.
     (define worker (make-worker storage))
     (check-eq?
      (issuance-result-disposition (process-issuance-work! worker storage))
      'completed)
     (define withdrawal
       (process-issuance-work! worker storage))
     (check-eq? (issuance-result-disposition withdrawal) 'released)
     (check-equal? (issuance-result-error-code withdrawal)
                   'evidence-binding-mismatch)
     (storage-close storage))))
