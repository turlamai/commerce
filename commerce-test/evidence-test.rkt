#lang racket/base

;; Issue #10 / #38 / ADR-0020: the durable verified-evidence boundary. A
;; hostile writer with full database access (a compromised edge role) forges
;; journal and outbox rows directly; the issuer must refuse to sign every
;; forged grant, must refuse redirected subjects against the append-only
;; checkout binding, and must refuse forged refunds — while completing every
;; genuinely signed payment, genuine refund proof, and legitimate withdrawal.

(require base64
         commerce
         commerce/alipay
         commerce/evidence
         commerce/issuer
         commerce/journal
         commerce/pancake
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         crypto
         crypto/libcrypto
         db
         json
         permit/envelope
         permit/issuer
         rackunit
         racket/file
         racket/list
         racket/string)

(parameterize ([crypto-factories (list libcrypto-factory)])
  (crypto-factories))

;; ---- fixture key material (generated per run, never committed) ----------

(define rsa-private-key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))

(define (public-key->pem key)
  (string-append
   "-----BEGIN PUBLIC KEY-----\n"
   (bytes->string/utf-8
    (base64-encode (pk-key->datum key 'SubjectPublicKeyInfo) #:line #f))
   "\n-----END PUBLIC KEY-----\n"))

(define alipay-public-key-pem
  (public-key->pem (pk-key->public-only-key rsa-private-key)))

(define-values (permit-private-key permit-public-key)
  (generate-ed25519-keypair))

;; ---- pinned catalog: the issuer's amount trust anchor -------------------

(define pro-offer
  (offer "taskly-pro-lifetime" "taskly" 'one-time (money "CNY" 2900)
         "taskly-pro-v1"))

(define lite-offer
  (offer "taskly-pro-lite" "taskly" 'one-time (money "CNY" 100)
         "taskly-pro-v1"))

(define taskly-policy
  (make-permit-entitlement-policy
   "taskly-pro-v1" 1
   #:subject-type 'person
   #:grants (list (make-permit-grant-policy
                   #:products '("taskly") #:edition "pro"))))

(define catalog
  (make-permit-policy-catalog (list pro-offer lite-offer)
                              (list taskly-policy)))

(define deleted-catalog
  ;; A deleted Offer is a tombstone: it must no longer sell, so it is absent
  ;; from the live offers and named only in the deletion list.
  (make-permit-policy-catalog (list lite-offer)
                              (list taskly-policy)
                              #:deleted-offer-ids '("taskly-pro-lifetime")))

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

;; ---- Alipay webhook fixtures --------------------------------------------

(define (sign-alipay-fields fields)
  (cons
   (cons "sign"
         (bytes->string/utf-8
          (base64-encode
           (parameterize ([crypto-factories (list libcrypto-factory)])
             (digest/sign rsa-private-key 'sha256
                          (string->bytes/utf-8
                           (alipay-signing-content fields))
                          #:pad 'pkcs1-v1.5))
           #:line #f)))
   fields))

(define (alipay-fields
         #:out-trade-no [out-trade-no "order_ev_001"]
         #:amount [amount "29.00"]
         #:status [status "TRADE_SUCCESS"])
  (list (cons "total_amount" amount)
        (cons "seller_id" "2088000000000000")
        (cons "out_trade_no" out-trade-no)
        (cons "app_id" "2026000000000000")
        (cons "notify_id" "notify_ev_001")
        (cons "trade_no" "202610301234567890")
        (cons "trade_status" status)
        (cons "sign_type" "RSA2")))

(define (escape-form-value value)
  ;; Escape literal + before encoding spaces to +, or decoded values would
  ;; not reproduce the exact signed bytes.
  (string-replace
   (string-replace
    (string-replace
     (string-replace
      (string-replace value "%" "%25") "+" "%2B")
     "/" "%2F")
    "=" "%3D")
   " " "+"))

(define (form-encode fields)
  (string->bytes/utf-8
   (string-join
    (for/list ([pair (in-list fields)])
      (string-append (car pair) "=" (escape-form-value (cdr pair))))
    "&")))

;; Signed full-refund query response, the exact bytes the refund slice
;; journals as payment-refunded evidence.
(define (signed-refund-query-response
         #:order [order "order_ev_001"]
         #:request [request "ref_ev_001"]
         #:amount [amount "29.00"]
         #:status [status "REFUND_SUCCESS"]
         #:refund-time [refund-time "2026-10-16 08:00:00"])
  (define json-content
    (jsexpr->string
     (hasheq 'code "10000"
             'out_trade_no order
             'trade_no "202610301234567890"
             'out_request_no request
             'refund_amount amount
             'refund_status status
             'gmt_refund_pay refund-time)))
  (define signature
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign rsa-private-key 'sha256
                   (string->bytes/utf-8 json-content)
                   #:pad 'pkcs1-v1.5)))
  (string->bytes/utf-8
   (string-append
    "{\"alipay_trade_fastpay_refund_query_response\":"
    json-content
    ",\"sign\":\""
    (bytes->string/utf-8 (base64-encode signature #:line #f))
    "\"}")))

;; GMT+8 wall-clock rendering of a UTC epoch second, matching the refund
;; module's settlement-time convention.
(define (gmt8 epoch-seconds)
  (define moment (seconds->date (+ epoch-seconds (* 8 3600)) #f))
  (define (pad2 value)
    (if (< value 10) (string-append "0" (number->string value))
        (number->string value)))
  (string-append
   (number->string (date-year moment))
   "-" (pad2 (date-month moment))
   "-" (pad2 (date-day moment))
   " " (pad2 (date-hour moment))
   ":" (pad2 (date-minute moment))
   ":" (pad2 (date-second moment))))

;; ---- storage and worker helpers -----------------------------------------

(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-evidence-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (clock-at epoch-seconds)
  (lambda () (values epoch-seconds (rfc3339-for epoch-seconds))))

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

(define alipay-binding-row
  (checkout-binding "order_ev_001" "alipay" "PROD_alipay_001"
                    "taskly-pro-lifetime" "customer-001" "CNY" 2900 2))

(define pancake-binding-row
  (checkout-binding "checkout-ev-001" "pancake" "PROD_srv_001"
                    "taskly-pro-lifetime" "customer-002" "CNY" 2900 2))

;; Opens storage, optionally seeds the append-only checkout binding, journals
;; one payment row, and projects it into a pending grant intent.
(define (open-grant-storage path payload event
                            #:binding [binding #f]
                            #:evidence [evidence #f])
  (define storage (open-sqlite-commerce-storage path))
  (when binding
    (storage-create-checkout-binding! storage binding #:created-at 1))
  (journal-accept! storage payload event
                   #:received-at 10
                   #:evidence evidence)
  (storage-project-next! storage #:processed-at 11)
  storage)

(define (alipay-grant-event payload
                            #:out-trade-no [out-trade-no "order_ev_001"]
                            #:amount [amount (money "CNY" 2900)]
                            #:subject [subject "customer-001"]
                            #:event-id [event-id "notify_ev_001"])
  (make-verified-payment-event
   "alipay" event-id (bytes->hex-string (sha256-bytes payload))
   'payment-succeeded out-trade-no
   "taskly-pro-lifetime" subject amount 1792108800))

(define (alipay-verifier storage
                         #:catalog [a-catalog catalog]
                         #:alipay-pem [pem alipay-public-key-pem])
  (make-issuance-evidence-verifier
   #:catalog a-catalog
   #:alipay-public-key-pem pem
   #:binding-lookup
   (lambda (order-id)
     (storage-checkout-binding-ref storage order-id))))

(define (worker-with-verifier verifier #:catalog [a-catalog catalog])
  (make-issuance-worker
   #:catalog a-catalog
   #:issuer issuer-name
   #:private-key permit-private-key
   #:key-id key-id
   #:trust-store trust-store
   #:clock (clock-at 100)
   #:evidence-verifier verifier))

(define (database-count path table)
  (define connection (sqlite3-connect #:database path #:mode 'read-only))
  (begin0
    (query-value connection (format "SELECT COUNT(*) FROM ~a" table))
    (disconnect connection)))

;; ---- Alipay adversarial cases -------------------------------------------

(test-case "a genuinely signed Alipay payment grants through verification"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'completed)
     (check-false (issuance-result-error-code result))
     (check-equal? (database-count path "commerce_entitlement_lineage") 1)
     (storage-close storage))))

(test-case "a forged journal row never produces a credential"
  (call-with-temporary-database
   (lambda (path)
     ;; Arbitrary attacker bytes with a matching digest and the canonical
     ;; fields of a real paid offer: exactly what a compromised edge with
     ;; arbitrary database writes can persist.
     (define payload #"attacker-controlled journal bytes")
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'alipay-form-invalid)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (check-equal? (database-count path "commerce_entitlement_revision") 0)
     (storage-close storage))))

(test-case "a journal amount the catalog never sells is refused first"
  (call-with-temporary-database
   (lambda (path)
     ;; Genuine Alipay-signed bytes for 29.00 presented with a rewritten
     ;; canonical amount: the pinned catalog anchor refuses before any
     ;; provider parsing happens.
     (define payload
       (form-encode (sign-alipay-fields (alipay-fields #:amount "29.00"))))
     (define storage
       (open-grant-storage
        path payload
        (alipay-grant-event payload #:amount (money "CNY" 1))
        #:binding alipay-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-amount-offer-mismatch)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "signed payload facts disagreeing with the row are refused"
  (call-with-temporary-database
   (lambda (path)
     ;; The row claims the catalog price, but the bytes were genuinely signed
     ;; for a different amount: verification must catch the disagreement.
     (define payload
       (form-encode (sign-alipay-fields (alipay-fields #:amount "1.00"))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-field-mismatch)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "a failed trade status cannot grant"
  (call-with-temporary-database
   (lambda (path)
     (define payload
       (form-encode
        (sign-alipay-fields (alipay-fields #:status "TRADE_CLOSED"))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-field-mismatch)
     (storage-close storage))))

(test-case "an offer the catalog never sold cannot be granted"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define forged-event
       (make-verified-payment-event
        "alipay" "notify_ev_001"
        (bytes->hex-string (sha256-bytes payload))
        'payment-succeeded "order_ev_001"
        "taskly-pro-ultra" "customer-001" (money "CNY" 2900)
        1792108800))
     (define storage (open-grant-storage path payload forged-event
                                         #:binding alipay-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-unknown-offer)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "a deleted offer cannot be granted even with genuine bytes"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define result
       (process-issuance-work!
        (worker-with-verifier
         (alipay-verifier storage #:catalog deleted-catalog)
         #:catalog deleted-catalog)
        storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-unknown-offer)
     (storage-close storage))))

(test-case "verification without a configured provider key fails closed"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define result
       (process-issuance-work!
        (worker-with-verifier (alipay-verifier storage #:alipay-pem #f))
        storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-verifier-unconfigured)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "an outbox row retargeted to a cheaper offer is refused"
  (call-with-temporary-database
   (lambda (path)
     ;; Outbox rows have no immutability trigger, so the hostile writer
     ;; points the pending grant at the cheap Offer. The claimed Offer must
     ;; equal the journaled event's Offer, so retargeting cannot steer the
     ;; price anchor away from the signed bytes.
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define connection (sqlite3-connect #:database path))
     (query-exec connection
                 "UPDATE commerce_issuance_outbox SET offer_id = 'taskly-pro-lite'")
     (disconnect connection)
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-field-mismatch)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "an outbox subject retargeted after projection is refused"
  (call-with-temporary-database
   (lambda (path)
     ;; Outbox rows are mutable: the hostile writer redirects the pending
     ;; grant to a different subject. The claimed subject must equal the
     ;; journaled event's subject, which in turn must equal the binding.
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define connection (sqlite3-connect #:database path))
     (query-exec connection
                 "UPDATE commerce_issuance_outbox SET subject_id = 'customer-999'")
     (disconnect connection)
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-field-mismatch)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "a genuine payment redirected to another subject is refused"
  (call-with-temporary-database
   (lambda (path)
     ;; The signed notification bytes are genuine for out_trade_no X, but the
     ;; forged journal row names a different subject than the one the
     ;; binding minted. Only the binding knows who X was minted for.
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage
        path payload
        (alipay-grant-event payload #:subject "customer-999")
        #:binding alipay-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-binding-mismatch)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "a journaled order without a durable binding is refused"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (alipay-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-binding-missing)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

;; ---- Pancake evidence ---------------------------------------------------

(define pancake-webhook-private-key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))

(define pancake-keyring
  (pancake-webhook-keyring
   (public-key->pem
    (pk-key->public-only-key pancake-webhook-private-key))
   (public-key->pem
    (pk-key->public-only-key
     (parameterize ([crypto-factories (list libcrypto-factory)])
       (generate-private-key (get-pk 'rsa) '((nbits 2048))))))))

(define (signed-pancake-webhook
         #:event-id [event-id "evt_ev_001"]
         #:body-override [body-override #f])
  (define now-ms
    (inexact->exact (floor (current-inexact-milliseconds))))
  (define body
    (or body-override
        (jsexpr->bytes
         (hash 'id event-id
               'timestamp "2026-11-03T00:00:00.000Z"
               'eventType "order.completed"
               'eventId "PAY_ev_001"
               'storeId "STO_ev_001"
               'storeName "Evidence Store"
               'data (hash 'orderId "checkout-ev-001")
               'mode "test"))))
  (define signature
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign pancake-webhook-private-key 'sha256
                   (bytes-append
                    (string->bytes/utf-8
                     (string-append (number->string now-ms) "."))
                    body)
                   #:pad 'pkcs1-v1.5)))
  (values body
          (string-append
           "t=" (number->string now-ms)
           ",v1="
           (bytes->string/utf-8 (base64-encode signature #:line #f)))))

(define (pancake-evidence header)
  (jsexpr->bytes
   (hasheq 'environment "test" 'signature_header header)))

(define (pancake-grant-event payload
                             #:subject [subject "customer-002"]
                             #:event-id [event-id "evt_ev_001"])
  (make-verified-payment-event
   "pancake" event-id (bytes->hex-string (sha256-bytes payload))
   'payment-succeeded "ORD_ev_001"
   "taskly-pro-lifetime" subject (money "CNY" 2900)
   1792108801))

(define (pancake-verifier storage)
  (make-issuance-evidence-verifier
   #:catalog catalog
   #:pancake-keyring pancake-keyring
   #:binding-lookup
   (lambda (order-id)
     (storage-checkout-binding-ref storage order-id))))

(test-case "a genuine Pancake webhook grants with journaled evidence"
  (call-with-temporary-database
   (lambda (path)
     (define-values (body header) (signed-pancake-webhook))
     (define storage
       (open-grant-storage path body (pancake-grant-event body)
                           #:binding pancake-binding-row
                           #:evidence (pancake-evidence header)))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (pancake-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'completed)
     (check-false (issuance-result-error-code result))
     (check-equal? (database-count path "commerce_entitlement_lineage") 1)
     (storage-close storage))))

(test-case "a Pancake row without journaled evidence is refused"
  (call-with-temporary-database
   (lambda (path)
     (define-values (body _header) (signed-pancake-webhook))
     (define storage
       (open-grant-storage path body (pancake-grant-event body)
                           #:binding pancake-binding-row))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (pancake-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-unverifiable)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "a Pancake payload tampered before journaling is refused"
  (call-with-temporary-database
   (lambda (path)
     ;; The journal row's bytes are not the bytes the signature covers: the
     ;; hostile writer journaled tampered content with a genuine header and
     ;; a matching canonical digest.
     (define-values (body header) (signed-pancake-webhook))
     (define tampered (bytes-append body #" "))
     (define storage
       (open-grant-storage path tampered (pancake-grant-event tampered)
                           #:binding pancake-binding-row
                           #:evidence (pancake-evidence header)))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (pancake-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'pancake-signature-invalid)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

(test-case "a Pancake subject redirected against the binding is refused"
  (call-with-temporary-database
   (lambda (path)
     (define-values (body header) (signed-pancake-webhook))
     (define storage
       (open-grant-storage
        path body (pancake-grant-event body #:subject "customer-999")
        #:binding pancake-binding-row
        #:evidence (pancake-evidence header)))
     (define result
       (process-issuance-work! (worker-with-verifier
                                (pancake-verifier storage))
                               storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-binding-mismatch)
     (check-equal? (database-count path "commerce_entitlement_lineage") 0)
     (storage-close storage))))

;; ---- refund evidence and withdrawal policy ------------------------------

(define (journal-refund-row! storage refund-raw
                             #:request-id [request-id "ref_ev_001"]
                             #:subject [subject "customer-001"]
                             #:occurred-at occurred-at)
  (journal-accept!
   storage refund-raw
   (make-verified-payment-event
    "alipay" (string-append "refund:" request-id)
    (bytes->hex-string (sha256-bytes refund-raw))
    'payment-refunded "order_ev_001"
    "taskly-pro-lifetime" subject (money "CNY" 2900)
    occurred-at)
   #:received-at 20))

(test-case "a genuine refund proof withdraws through re-verification"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define verifier (alipay-verifier storage))
     (check-eq?
      (issuance-result-disposition
       (process-issuance-work! (worker-with-verifier verifier) storage))
      'completed)
     ;; Settlement time is GMT+8-rendered from the exact epoch the journal
     ;; row records; the issuer must agree with the signed bytes.
     (define refunded-epoch 1793462400)
     (define refund-raw
       (signed-refund-query-response
        #:refund-time (gmt8 refunded-epoch)))
     (journal-refund-row! storage refund-raw
                          #:occurred-at refunded-epoch)
     (storage-project-next! storage #:processed-at 21)
     (define result
       (process-issuance-work! (worker-with-verifier verifier) storage))
     (check-eq? (issuance-result-disposition result) 'completed)
     (check-equal? (database-count path "commerce_entitlement_revision") 2)
     (storage-close storage))))

(test-case "forged refund bytes can no longer force a withdrawal"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define verifier (alipay-verifier storage))
     (check-eq?
      (issuance-result-disposition
       (process-issuance-work! (worker-with-verifier verifier) storage))
      'completed)
     (define refund-raw #"attacker reconciliation bytes")
     (journal-refund-row! storage refund-raw
                          #:occurred-at 1793462400)
     (storage-project-next! storage #:processed-at 21)
     (define result
       (process-issuance-work! (worker-with-verifier verifier) storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'alipay-query-invalid)
     (check-equal? (database-count path "commerce_entitlement_revision") 1)
     (storage-close storage))))

(test-case "a refund redirected to another subject is refused"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define verifier (alipay-verifier storage))
     (process-issuance-work! (worker-with-verifier verifier) storage)
     ;; Genuine signed refund bytes for the order, journaled against a
     ;; different subject than the binding minted. The projection layer
     ;; blocks the subject swap on its own; a fully compromised edge also
     ;; rewrites the order projection to steer past that check, so the test
     ;; does both and expects the issuer's binding fence to be the wall.
     (define refunded-epoch 1793462400)
     (define refund-raw
       (signed-refund-query-response #:refund-time (gmt8 refunded-epoch)))
     (define connection (sqlite3-connect #:database path))
     (query-exec connection
                 "UPDATE commerce_order_projection SET subject_id = 'customer-999'")
     (disconnect connection)
     (journal-refund-row! storage refund-raw
                          #:subject "customer-999"
                          #:occurred-at refunded-epoch)
     (storage-project-next! storage #:processed-at 21)
     (define result
       (process-issuance-work! (worker-with-verifier verifier) storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'evidence-binding-mismatch)
     (check-equal? (database-count path "commerce_entitlement_revision") 1)
     (storage-close storage))))

(test-case "a refund journaled under the wrong request id is refused"
  (call-with-temporary-database
   (lambda (path)
     (define payload (form-encode (sign-alipay-fields (alipay-fields))))
     (define storage
       (open-grant-storage path payload (alipay-grant-event payload)
                           #:binding alipay-binding-row))
     (define verifier (alipay-verifier storage))
     (process-issuance-work! (worker-with-verifier verifier) storage)
     (define refunded-epoch 1793462400)
     (define refund-raw
       (signed-refund-query-response #:refund-time (gmt8 refunded-epoch)))
     (journal-refund-row! storage refund-raw
                          #:request-id "ref_other"
                          #:occurred-at refunded-epoch)
     (storage-project-next! storage #:processed-at 21)
     (define result
       (process-issuance-work! (worker-with-verifier verifier) storage))
     (check-eq? (issuance-result-disposition result) 'released)
     (check-equal? (issuance-result-error-code result)
                   'alipay-refund-mismatch)
     (check-equal? (database-count path "commerce_entitlement_revision") 1)
     (storage-close storage))))
