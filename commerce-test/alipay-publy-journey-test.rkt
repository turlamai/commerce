#lang racket/base

;; Synthetic payment evidence only. No provider endpoint or real key is used.
(require rackunit json racket/file racket/list racket/string base64
         crypto crypto/libcrypto
         commerce commerce/admission commerce/alipay commerce/alipay/server
         commerce/alipay/checkout-coordinator commerce/alipay/checkout-idempotency
         commerce/journal commerce/storage commerce/storage/sqlite
         commerce/permit commerce/issuer commerce/hosted-proof
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
