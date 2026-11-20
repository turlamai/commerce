#lang racket/base

;; Synthetic payment evidence only. No provider endpoint or real key is used.
(require rackunit json racket/file racket/list racket/string base64
         crypto crypto/libcrypto
         commerce commerce/admission commerce/alipay commerce/alipay/server
         commerce/alipay/checkout-coordinator commerce/alipay/checkout-idempotency
         commerce/journal commerce/storage commerce/storage/sqlite
         commerce/permit commerce/issuer commerce/hosted-proof commerce/evidence commerce/alipay/refund
         permit/trust permit/issuer)

(define (rsa-key)
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
(define (rsa-sign key text)
  (bytes->string/utf-8
   (base64-encode
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign key 'sha256 (string->bytes/utf-8 text) #:pad 'pkcs1-v1.5))
    #:line #f)))
(define (public-pem key)
  (string-append "-----BEGIN PUBLIC KEY-----\n"
                 (bytes->string/utf-8 (base64-encode (pk-key->datum (pk-key->public-only-key key) 'SubjectPublicKeyInfo) #:line #f))
                 "\n-----END PUBLIC KEY-----\n"))
(define (form-value value)
  (for/fold ([v value]) ([p (in-list (list (cons "%" "%25") (cons "+" "%2B")
                                           (cons "/" "%2F") (cons "=" "%3D") (cons " " "+")))])
    (string-replace v (car p) (cdr p))))

(test-case "synthetic Alipay payment projects once and produces a scoped hosted proof"
  (define dir (make-temporary-file "commerce-publy-journey-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define admit-file (build-path dir "admission.json"))
     (call-with-output-file admit-file
       (lambda (out)
         (write-json (hasheq 'version 1 'provider "alipay" 'environment "sandbox"
            'merchant_app_id "fixture-app" 'seller_id "fixture-seller" 'product_category "fixture"
            'admission_reference "fixture" 'cost_reference "fixture" 'checkout_api "alipay.trade.page.pay"
            'read_api "alipay.trade.query" 'approved_at 1 'expires_at 4102444800
            'capabilities (list (hasheq 'offer_id "publy-personal-monthly" 'product_id "publy"
              'method "alipay" 'transaction_type "one-time" 'currency "CNY" 'amount_minor 2900
              'min_minor 1 'max_minor 100000))) out)))
     (define storage (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
     (define claim-file (build-path dir "claims.sqlite"))
     (initialize-sqlite-alipay-checkout-claims! claim-file)
     (define claim! (make-sqlite-alipay-checkout-claimer claim-file))
     (define merchant (rsa-key))
     (define provider (rsa-key))
     (define selected (offer "publy-personal-monthly" "publy" 'one-time (money "CNY" 2900) "fixture-policy"))
     (dynamic-wind
      void
      (lambda ()
        (define-values (order fields)
          (create-alipay-checkout! storage #:service-id "fixture-service" #:request-id "request-1" #:subject-id "account-a"
           #:offer selected #:authorize (lambda (s p o u) #t) #:claim! claim! #:admission (read-provider-admission admit-file)
           #:environment "sandbox" #:app-id "fixture-app" #:seller-id "fixture-seller" #:private-key merchant
           #:title "Publy" #:notify-url "https://example.test/notify" #:return-url "https://example.test/return"
           #:timestamp "2026-10-30 12:30:00" #:at 1793363400))
        (define (query-response binding)
          (define payload (jsexpr->string (hasheq 'code "10000" 'app_id "fixture-app" 'seller_id "fixture-seller"
            'out_trade_no (alipay-binding-order-id binding) 'trade_no "fixture-trade" 'trade_status "TRADE_SUCCESS" 'total_amount "29.00")))
          (string->bytes/utf-8 (string-append "{\"alipay_trade_query_response\":" payload ",\"sign\":\"" (rsa-sign provider payload) "\"}")))
        (define notification
          (list (cons "app_id" "fixture-app") (cons "seller_id" "fixture-seller") (cons "out_trade_no" order)
                (cons "notify_id" "fixture-notify") (cons "gmt_payment" "2026-10-30 12:30:00")
                (cons "trade_no" "fixture-trade") (cons "trade_status" "TRADE_SUCCESS")
                (cons "total_amount" "29.00") (cons "sign_type" "RSA2")))
        (define signed (cons (cons "sign" (rsa-sign provider (alipay-signing-content notification))) notification))
        (define raw (string->bytes/utf-8 (string-join (for/list ([p (in-list signed)])
          (string-append (car p) "=" (form-value (cdr p)))) "&")))
        (define webhook (make-alipay-webhook-endpoint #:app-id "fixture-app" #:seller-id "fixture-seller"
                          #:alipay-public-key (public-pem provider) #:query-order query-response #:storage storage))
        (define-values (first first-body) (handle-alipay-webhook-post webhook raw))
        (check-equal? first 200)
        (define-values (duplicate duplicate-body) (handle-alipay-webhook-post webhook raw))
        (check-equal? duplicate 200)
        (define-values (bad bad-body) (handle-alipay-webhook-post webhook (bytes-append raw #"&app_id=forged")))
        (check-equal? bad 401)
        (storage-project-next! storage #:processed-at 1793363401)
        (check-false (storage-project-next! storage #:processed-at 1793363401))
        (define-values (private public) (generate-ed25519-keypair))
        (define trust (jsexpr->trust-store (hasheq 'protocol "permit-trust-store" 'version 1 'issuer "fixture-issuer"
          'keys (hasheq 'test (hasheq 'algorithm "Ed25519" 'public_key (public-key->base64 public)
           'status "active" 'purposes '("entitlement") 'not_before 'null 'not_after 'null)))))
        (define catalog (make-permit-policy-catalog (list selected)
          (list (make-permit-entitlement-policy "fixture-policy" 1 #:subject-type 'account
            #:grants (list (make-permit-grant-policy #:products '("publy") #:edition "personal"))
            #:constraints (make-permit-constraints-policy #:use-expires-at "2099-01-01T00:00:00Z")))))
        (define worker (make-issuance-worker #:catalog catalog #:issuer "fixture-issuer" #:private-key private
          #:key-id "test" #:trust-store trust #:clock (lambda () (values 1793363402 "2026-10-30T04:30:02Z"))))
        (check-equal? (issuance-result-disposition (process-issuance-work! worker storage)) 'completed)
        (check-false (process-issuance-work! worker storage))
        (define proof (current-verified-entitlement-proof storage #:issuer "fixture-issuer" #:subject-type "account"
          #:subject-id "account-a" #:offer-id "publy-personal-monthly" #:product-id "publy"
          #:authorize (lambda (i t s o p) #t) #:trust-store trust #:at "2026-11-01T00:00:00Z"))
        (check-equal? (hash-ref proof 'status) "verified-proof")
        (define other (current-verified-entitlement-proof storage #:issuer "fixture-issuer" #:subject-type "account"
          #:subject-id "account-b" #:offer-id "publy-personal-monthly" #:product-id "publy"
          #:authorize (lambda (i t s o p) #t) #:trust-store trust #:at "2026-11-01T00:00:00Z"))
        (check-not-equal? (hash-ref other 'status) "verified-proof"))
      (lambda () (storage-close storage))))
   (lambda () (delete-directory/files dir))))

(test-case "monthly native callback, repurchase, old/new refunds and restart preserve scoped rights"
  (define dir (make-temporary-file "commerce-month-journey-~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define path (build-path dir "commerce.sqlite"))
      (define storage (open-sqlite-commerce-storage path))
      (define provider (rsa-key))
      (define pub (public-pem provider))
      (define dates (hash "month-a" "2026-10-16 08:00:00"
                          "month-b" "2026-11-16 08:00:00"))
      (define (json-signed method data)
        (define payload (jsexpr->string data))
        (string->bytes/utf-8
          (string-append "{\"" method "\":" payload ",\"sign\":\""
                         (rsa-sign provider payload) "\"}")))
      (define (endpoint)
        (make-alipay-webhook-endpoint #:app-id "fixture-app" #:seller-id "fixture-seller"
          #:alipay-public-key pub #:storage storage
          #:query-order (lambda (binding)
            (define order (alipay-binding-order-id binding))
            (json-signed "alipay_trade_query_response"
              (hasheq 'code "10000" 'app_id "fixture-app" 'seller_id "fixture-seller"
                'out_trade_no order 'trade_no (string-append "trade-" order)
                'trade_status "TRADE_SUCCESS" 'total_amount "29.00")))))
      (define (callback order)
        (define fields (list (cons "app_id" "fixture-app") (cons "seller_id" "fixture-seller")
          (cons "out_trade_no" order) (cons "notify_id" (string-append "notify-" order))
          (cons "gmt_payment" (hash-ref dates order)) (cons "trade_no" (string-append "trade-" order))
          (cons "trade_status" "TRADE_SUCCESS") (cons "total_amount" "29.00") (cons "sign_type" "RSA2")))
        (define signed (cons (cons "sign" (rsa-sign provider (alipay-signing-content fields))) fields))
        (define raw (string->bytes/utf-8 (string-join (for/list ([p signed])
          (string-append (car p) "=" (form-value (cdr p)))) "&")))
        (define-values (status ack) (handle-alipay-webhook-post (endpoint) raw))
        (check-equal? status 200)
        (define-values (repeated repeated-ack) (handle-alipay-webhook-post (endpoint) raw))
        (check-equal? repeated 200))
      (define-values (private public) (generate-ed25519-keypair))
      (define trust (jsexpr->trust-store (hasheq 'protocol "permit-trust-store" 'version 1 'issuer "monthly-issuer"
        'keys (hasheq 'test (hasheq 'algorithm "Ed25519" 'public_key (public-key->base64 public)
          'status "active" 'purposes '("entitlement") 'not_before 'null 'not_after 'null)))))
      (define catalog (make-permit-policy-catalog
        (list (offer "publy-personal-monthly" "publy" 'one-time (money "CNY" 2900) "monthly-v1"))
        (list (make-permit-entitlement-policy "monthly-v1" 1 #:subject-type 'account
          #:grants (list (make-permit-grant-policy #:products '("publy") #:edition "personal"))
          #:constraints (make-permit-constraints-policy #:use-duration-months 1)))))
      (define (process!)
        (storage-project-next! storage #:processed-at 1794873600)
        (define result (process-issuance-work!
          (make-issuance-worker #:catalog catalog #:issuer "monthly-issuer" #:private-key private
            #:key-id "test" #:trust-store trust #:clock (lambda () (values 1794873601 "2026-11-17T00:00:01Z"))
            #:evidence-verifier (make-issuance-evidence-verifier #:catalog catalog #:alipay-public-key-pem pub
              #:alipay-app-id "fixture-app" #:alipay-seller-id "fixture-seller"
              #:binding-lookup (lambda (order) (storage-checkout-binding-ref storage order)))) storage))
        (check-eq? (issuance-result-disposition result) 'completed))
      (define (proof [account "account-a"] [at "2026-11-17T00:00:02Z"])
        (current-verified-entitlement-proof storage #:issuer "monthly-issuer" #:subject-type "account"
          #:subject-id account #:offer-id "publy-personal-monthly" #:product-id "publy"
          #:authorize (lambda args #t) #:trust-store trust #:at at))
      (for ([order '("month-a" "month-b")])
        (storage-create-checkout-binding! storage
          (checkout-binding order "alipay" "publy" "publy-personal-monthly" "account-a" "CNY" 2900 2)
          #:created-at 1)
        (callback order)
        (process!))
      (check-equal? (hash-ref (proof) 'status) "verified-proof")
      (check-not-equal? (hash-ref (proof "account-b") 'status) "verified-proof")
      (storage-close storage)
      (set! storage (open-sqlite-commerce-storage path))
      (check-equal? (hash-ref (proof) 'status) "verified-proof")
      (check-equal? (hash-ref (proof "account-a" "2026-12-16T00:00:00Z") 'status) "not-usable")
      (define (refund order)
        (define binding (alipay-binding "fixture-app" "fixture-seller" order
          "publy-personal-monthly" "account-a" (money "CNY" 2900)))
        (define request (string-append "refund-" order))
        (define raw (json-signed "alipay_trade_fastpay_refund_query_response"
          (hasheq 'code "10000" 'out_trade_no order 'trade_no (string-append "trade-" order)
            'out_request_no request 'refund_amount "29.00" 'refund_status "REFUND_SUCCESS"
            'gmt_refund_pay "2026-11-17 08:00:00")))
        (journal-alipay-full-refund! storage raw pub binding request #:received-at 1794873600)
        (check-equal? (hash-ref (proof) 'status) "refund-pending")
        (process!))
      (refund "month-a")
      (check-equal? (hash-ref (proof) 'status) "verified-proof")
      (callback "month-a")
      (check-false (storage-project-next! storage #:processed-at 1794873602))
      (check-equal? (hash-ref (proof) 'status) "verified-proof")
      (refund "month-b")
      (check-equal? (hash-ref (proof) 'status) "recorded-withdrawal")
      (callback "month-b")
      (check-equal? (hash-ref (proof) 'status) "recorded-withdrawal")
      (storage-close storage))
    (lambda () (delete-directory/files dir))))
