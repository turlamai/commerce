#lang racket/base

(require rackunit json racket/file
         crypto crypto/libcrypto
         commerce commerce/admission commerce/hosted-auth
         commerce/hosted-replay/sqlite
         commerce/alipay/checkout-http commerce/alipay/checkout-idempotency
         commerce/storage commerce/storage/sqlite)

(test-case "authenticated service checkout uses only server-selected price and stable order"
  (define dir (make-temporary-file "commerce-checkout-http-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define admission-file (build-path dir "admission.json"))
     (call-with-output-file admission-file
       (lambda (out)
         (write-json
          (hasheq 'version 1 'provider "alipay" 'environment "sandbox"
                  'merchant_app_id "fixture-app" 'seller_id "fixture-seller"
                  'product_category "fixture" 'admission_reference "fixture" 'cost_reference "fixture"
                  'checkout_api "alipay.trade.page.pay" 'read_api "alipay.trade.query"
                  'approved_at 100 'expires_at 1000
                  'capabilities (list (hasheq 'offer_id "publy-personal-monthly" 'product_id "publy"
                    'method "alipay" 'transaction_type "one-time" 'currency "CNY"
                    'amount_minor 2900 'min_minor 1 'max_minor 100000))) out)))
     (define store (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
     (define claims-path (build-path dir "claims.sqlite"))
     (initialize-sqlite-alipay-checkout-claims! claims-path)
     ;; Use the production-style durable nonce boundary, not a test-only hash.
     ;; A new process/claimer must observe the same replay evidence.
     (define replay-path (build-path dir "replay.sqlite"))
     (initialize-sqlite-hosted-replay-store! replay-path)
     (define replay-claim!
       (make-sqlite-hosted-replay-claimer replay-path #:now (lambda () 500)))
     (define service-key (make-bytes 32 107))
     (define signer (parameterize ([crypto-factories (list libcrypto-factory)])
                      (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
     (define service
       (make-alipay-checkout-http-endpoint
        #:storage store #:resolve-key (lambda (id) (and (equal? id "service") service-key))
        #:allow-scope (lambda (service issuer type subject offer product)
                        (and (equal? service "service") (equal? issuer "fixture")
                             (equal? type "account") (member subject '("account-a" "account-c"))
                             (equal? offer "publy-personal-monthly") (equal? product "publy")))
        #:claim-once! replay-claim!
        #:checkout-claim! (make-sqlite-alipay-checkout-claimer claims-path)
        #:resolve-offer (lambda (product id)
                          (and (equal? product "publy") (equal? id "publy-personal-monthly")
                               (offer id product 'one-time (money "CNY" 2900) "fixture-policy")))
        #:title "Publy Personal" #:admission (read-provider-admission admission-file)
        #:environment "sandbox" #:app-id "fixture-app" #:seller-id "fixture-seller"
        #:private-key signer #:notify-url "https://example.test/notify" #:return-url "https://example.test/return"
        #:clock (lambda () 500)))
     (define request (hasheq 'issuer "fixture" 'subject_type "account" 'subject_id "account-a"
                             'offer_id "publy-personal-monthly" 'product_id "publy" 'request_id "request-1"))
     (check-false (regexp-match? #rx"fixture-seller|kkkkkkkk" (format "~v" service)))
     (define (call body nonce #:mac [override #f])
       (define raw (jsexpr->bytes body))
       (define mac (or override (bytes->hex-string
                    (hosted-request-mac service-key #:service-id "service" #:method "POST"
                     #:path "/v1/hosted/alipay-checkout" #:timestamp 500 #:nonce nonce
                     #:issuer (hash-ref body 'issuer) #:subject-type (hash-ref body 'subject_type)
                     #:subject-id (hash-ref body 'subject_id) #:offer-id (hash-ref body 'offer_id)
                     #:product-id (hash-ref body 'product_id) #:body raw))))
       (define-values (status result)
         (handle-alipay-checkout-http-post service #:method "POST" #:path "/v1/hosted/alipay-checkout"
           #:body raw #:service-id "service" #:timestamp "500" #:nonce nonce #:mac-hex mac))
       (values status (bytes->jsexpr result)))
     (dynamic-wind
      void
      (lambda ()
        (define-values (bad bad-body) (call request "nonce-000000000001" #:mac (make-string 64 #\0)))
        (check-equal? bad 401)
        (define-values (extra extra-body) (call (hash-set request 'amount 1) "nonce-000000000002"))
        (check-equal? extra 400)
        (define-values (wrong wrong-body) (call (hash-set request 'subject_id "account-b") "nonce-000000000003"))
        (check-equal? wrong 401)
        (define-values (ok first) (call request "nonce-000000000004"))
        (check-equal? ok 200)
        (check-equal? (hash-ref first 'status) "checkout-ready")
        (define fields (hash-ref first 'fields))
        (check-equal? (hash-ref (string->jsexpr (hash-ref fields 'biz_content)) 'total_amount) "29.00")
        (define-values (replay replay-body) (call request "nonce-000000000004"))
        (check-equal? replay 401)
        ;; A second claimer simulates restarting the HTTP edge against the
        ;; existing SQLite replay state; the previous nonce stays spent.
        (check-false
         ((make-sqlite-hosted-replay-claimer replay-path #:now (lambda () 500))
          "service" "nonce-000000000004" 801))
        (define-values (again second) (call request "nonce-000000000005"))
        (check-equal? again 200)
        (check-equal? (hash-ref first 'order_id) (hash-ref second 'order_id))
        (define-values (conflict conflict-body) (call (hash-set request 'subject_id "account-c") "nonce-000000000006"))
        (check-equal? conflict 409)
        (check-equal? (hash-ref conflict-body 'error) "checkout-conflict")
        ;; Loss of nonce history is not an authorization to reset replay state.
        ;; The handler must refuse rather than silently create a new database.
        (delete-file replay-path)
        (define-values (lost lost-body)
          (call (hash-set request 'request_id "request-after-loss")
                "nonce-000000000007"))
        (check-equal? lost 401)
        (check-equal? (checkout-binding-subject-id
                       (storage-checkout-binding-ref store
                                                     (hash-ref first 'order_id)))
                      "account-a"))
      (lambda () (storage-close store))))
   (lambda () (delete-directory/files dir))))
