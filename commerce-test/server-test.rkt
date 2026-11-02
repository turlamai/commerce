#lang racket/base

(require commerce
         commerce/issuer
         commerce/journal
         commerce/pancake
         commerce/permit
         commerce/provider
         commerce/server
         commerce/storage
         commerce/storage/sqlite
         base64
         db
         crypto
         crypto/libcrypto
         (only-in net/http-easy post response-status-code response-body)
         permit/envelope
         permit/issuer
         json
         net/url
         rackunit
         racket/file
         racket/match
         racket/string
         web-server/http)

(define (parse-json payload)
  (string->jsexpr (bytes->string/utf-8 payload)))

(require crypto)


(parameterize ([crypto-factories (list libcrypto-factory)])

  (define usd-29 (money "USD" 2900))

  (define (pem label key-datum)
    (define encoded
      (bytes->string/utf-8 (base64-encode key-datum #:line #f)))
    (string-append
     "-----BEGIN " label "-----\n"
     (string-join (regexp-match* #px".{1,64}" encoded) "\n")
     "\n-----END " label "-----\n"))

  ;; Pancake test-side trust and merchant keys, generated per run.
  (define webhook-private-key
    (generate-private-key (get-pk 'rsa) '((nbits 2048))))
  (define webhook-public-key-pem
    (pem "PUBLIC KEY"
         (pk-key->datum
          (pk-key->public-only-key webhook-private-key)
          'SubjectPublicKeyInfo)))
  (define production-public-key-pem
    (pem "PUBLIC KEY"
         (pk-key->datum
          (pk-key->public-only-key
           (generate-private-key (get-pk 'rsa) '((nbits 2048))))
          'SubjectPublicKeyInfo)))
  (define merchant-private-key-pem
    (pem "PRIVATE KEY"
         (pk-key->datum webhook-private-key 'OneAsymmetricKey)))

  (define keyring
    (pancake-webhook-keyring webhook-public-key-pem
                             production-public-key-pem))

  ;; The claim-portal worker signs with its own Permit keypair.
  (define-values (claim-private-key claim-public-key)
    (generate-ed25519-keypair))
  (define claim-trust-store
    (jsexpr->trust-store
     (hasheq 'protocol "permit-trust-store"
             'version 1
             'issuer "com.turinglambdaai"
             'keys
             (hasheq 'test-2026
                     (hasheq 'algorithm "Ed25519"
                             'public_key
                             (public-key->base64 claim-public-key)
                             'status "active"
                             'purposes '("entitlement")
                             'not_before 'null
                             'not_after 'null)))))

  (define binding
    (pancake-order-binding
     "checkout-server-001" "PROD_srv_001" "taskly-pro-lifetime"
     "customer-server-001" usd-29 2))

  (define (order-response)
    (jsexpr->bytes
     (hash 'data
           (hash 'onetimeOrder
                 (hash 'id "ORD_srv_001"
                       'status "completed"
                       'testMode #t
                       'currency "USD"
                       'orderMerchantExternalId "ORD_srv_001"
                       'store (hash 'id "STO_srv_001")
                       'onetimeProduct (hash 'id "PROD_srv_001")
                       'payments
                       (list
                        (hash 'id "PAY_srv_001"
                              'status "succeeded"
                              'snapshotAmountDetails
                              (hash 'currency "USD" 'total "29.00"))))))))

  (define merchant-client
    (make-pancake-merchant-client
     "MER_srv001" merchant-private-key-pem
     #:environment 'test
     #:clock (lambda () 1792108800)
     #:transport
     (lambda (endpoint headers body connect-timeout request-timeout)
       (values 200 (order-response)))))

  ;; One unique directory per database so rapid calls never share a path.
  (define (call-with-temporary-database proc)
    (define directory
      (make-temporary-file "commerce-server-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (proc (build-path directory "commerce.sqlite")))
      (lambda ()
        (delete-directory/files directory))))

  (define (call-with-endpoint proc)
    (call-with-temporary-database
     (lambda (path)
       (define storage (open-sqlite-commerce-storage path))
       (storage-create-checkout-binding!
        storage
        (checkout-binding "ORD_srv_001" "pancake" "PROD_srv_001"
                          "taskly-pro-lifetime" "customer-server-001"
                          "USD" 2900 2)
        #:created-at 1)
       (define endpoint
         (make-webhook-endpoint
          #:keyring keyring
          #:environment 'test
          #:merchant-client merchant-client
          #:binding-lookup
          (lambda (order-id)
            (storage-checkout-binding-ref storage order-id))
          #:storage storage))
       (proc storage endpoint path))))

  (define (iso-8601 epoch-seconds)
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
     ":" (pad2 (date-second moment)) ".000Z"))

  ;; Webhook fixtures carry a fresh timestamp so they sit inside the
  ;; replay-tolerance window no matter when the suite runs.
  (define (signed-webhook
           #:event-id [event-id "evt_srv_001"]
           #:data [data (hash 'orderId "ORD_srv_001")])
    (define now-ms (inexact->exact (floor (current-inexact-milliseconds))))
    (define body
      (jsexpr->bytes
       (hash 'id event-id
             'timestamp (iso-8601 (quotient now-ms 1000))
             'eventType "order.completed"
             'eventId "PAY_srv_001"
             'storeId "STO_srv_001"
             'storeName "Server Store"
             'data data
             'mode "test")))
    (define signature
      (digest/sign webhook-private-key 'sha256
                   (bytes-append (string->bytes/utf-8
                                  (string-append (number->string now-ms) "."))
                                 body)
                   #:pad 'pkcs1-v1.5))
    (values body
            (string-append
             "t=" (number->string now-ms)
             ",v1="
             (bytes->string/utf-8
              (base64-encode signature #:line #f)))))

  (test-case "a valid webhook is journaled exactly once through the handler"
    (call-with-endpoint
     (lambda (storage endpoint path)
       (define-values (body header) (signed-webhook))
       (define-values (status payload)
         (handle-webhook-post endpoint body header))
       (check-eq? status 200)
       (check-true (hash-ref (parse-json payload) 'accepted))
       (check-equal? (hash-ref (parse-json payload) 'disposition) "accepted")
       ;; Exact redelivery acknowledges without a second journal row.
       (define-values (replay-status replay-payload)
         (handle-webhook-post endpoint body header))
       (check-eq? replay-status 200)
       (check-equal? (hash-ref (parse-json replay-payload) 'disposition)
                  "replayed")
       (define connection
         (sqlite3-connect #:database path #:mode 'read-only))
       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM commerce_event_journal")
        1)
       (disconnect connection)
       (storage-close storage))))

  (test-case "authentication failures are 401 and journal nothing"
    (call-with-endpoint
     (lambda (storage endpoint path)
       (define-values (body header) (signed-webhook))
       (define-values (status payload)
         (handle-webhook-post endpoint
                              (bytes-append body #"tampered")
                              header))
       (check-eq? status 401)
       (check-false (hash-ref (parse-json payload) 'accepted))
       (check-false
        (storage-order-ref storage "pancake" "ORD_srv_001"))
       (storage-close storage))))

  (test-case "readyz renders the readiness snapshot"
    (call-with-endpoint
     (lambda (storage endpoint path)
       (define-values (status body)
         (handle-readyz endpoint))
       (check-eq? status 200)
       (define snapshot (parse-json body))
       (check-equal? (hash-ref snapshot 'schema-version) 8)
       (check-equal? (hash-ref snapshot 'journal-unprojected) 0)
       (check-equal? (hash-ref snapshot 'warnings) '())
       (storage-close storage))))

  (test-case "the claim portal fulfills once and refuses reuse"
    (call-with-endpoint
     (lambda (storage endpoint path)
       (define issuance-worker
         (make-issuance-worker
          #:catalog
          (make-permit-policy-catalog
           (list (offer "taskly-pro-lifetime" "taskly" 'one-time
                        usd-29 "taskly-pro-v1"))
           (list
            (make-permit-entitlement-policy
             "taskly-pro-v1" 1
             #:subject-type 'person
             #:grants
             (list (make-permit-grant-policy
                    #:products '("taskly"))))))
          #:issuer "com.turinglambdaai"
          #:private-key claim-private-key
          #:key-id "test-2026"
          #:trust-store claim-trust-store
          #:clock (lambda () (values 100 "2026-10-21T00:00:00Z"))
          ;; The portal fulfills with the real clock, so the test window
          ;; must comfortably outlive it.
          #:claim-window-seconds 10000000000))
       ;; Push one paid order through so a claim exists.
       (define payload #"claim portal payment")
       (journal-accept!
        storage payload
        (make-verified-payment-event
         "mock" "evt_claim"
         (bytes->hex-string (sha256-bytes payload)) 'payment-succeeded
         "ord_claim" "taskly-pro-lifetime" "customer-server-001"
         usd-29 1792108800)
        #:received-at 10)
       (storage-project-next! storage #:processed-at 11)
       (define result
         (process-issuance-work! issuance-worker storage))
       (check-eq? (issuance-result-disposition result) 'completed)
       (define token (issuance-result-claim-token result))

       (define-values (status envelope)
         (handle-claim-post endpoint token))
       (check-eq? status 200)
       (define claim-envelope (parse-json envelope))
       (check-true (hash? claim-envelope))
       (check-equal? (hash-ref claim-envelope 'key_id) "test-2026")
       ;; Reuse fails 409 without leaking anything.
       (define-values (replay-status replay-payload)
         (handle-claim-post endpoint token))
       (check-eq? replay-status 409)
       (check-equal? (hash-ref (parse-json replay-payload) 'error)
                     "already-claimed")
       ;; Unknown tokens are 404.
       (define-values (missing-status missing-payload)
         (handle-claim-post endpoint "no-such-token"))
       (check-eq? missing-status 404)
       (check-false (hash-ref (parse-json missing-payload) 'fulfilled))
       (storage-close storage))))

  (test-case "unknown checkout bindings are 404 without journaling"
    (call-with-endpoint
     (lambda (storage endpoint path)
       (define-values (body header)
         (signed-webhook
          #:event-id "evt_srv_002"
          #:data (hash 'orderId "ORD_unknown")))
       (define-values (status payload)
         (handle-webhook-post endpoint body header))
       (check-eq? status 404)
       (check-false (hash-ref (parse-json payload) 'accepted))
       (storage-close storage))))
)
