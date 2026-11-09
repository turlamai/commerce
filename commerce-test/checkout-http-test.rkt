#lang racket/base
(require rackunit
         json
         racket/file
         file/sha1
         commerce/admission
         commerce/checkout-http
         commerce/hosted-auth
         commerce/hosted-replay/sqlite
         commerce/storage
         commerce/storage/sqlite)

(define now (current-seconds))
(define key (make-bytes 32 42))
(define service-id "publy")
(define offering "publy-personal-monthly")
(define subject "publy_account_test")
(define issuer "publy")

(define admission-json
  (hasheq 'version 1 'provider "alipay" 'environment "sandbox"
          'merchant_app_id "test-app" 'seller_id "test-seller"
          'product_category "software" 'admission_reference "test-only"
          'cost_reference "test-only" 'checkout_api "alipay.trade.page.pay"
          'read_api "alipay.trade.query" 'approved_at (- now 60) 'expires_at (+ now 3600)
          'capabilities (list
                         (hasheq 'offer_id offering 'product_id "publy" 'method "alipay"
                                 'transaction_type "one-time" 'currency "CNY"
                                 'amount_minor 2900 'min_minor 2900 'max_minor 2900))))
(define dir (make-temporary-file "checkout-http-~a" 'directory))
(define admission-path (build-path dir "admission.json"))
(call-with-output-file admission-path #:exists 'replace
  (lambda (out) (write-json admission-json out)))
(define admission (with-handlers ([exn:fail? (lambda (e) (displayln (exn-message e)) (raise e))]) (read-provider-admission admission-path)))
(define storage (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
(define replay-path (build-path dir "replay.sqlite"))
(initialize-sqlite-hosted-replay-store! replay-path)

(define (make-service)
  (make-checkout-http-service
   #:admission admission #:admission-json admission-json
   #:storage storage
   #:signer (lambda (binding)
              (list (cons "app_id" "test-app") (cons "method" "alipay.trade.page.pay")))
   #:service-id service-id #:service-key key #:issuer issuer
   #:app-id "test-app" #:seller-id "test-seller"
   #:gateway "https://openapi-sandbox.dl.alipaydev.com/gateway.do"
   #:notify-url "https://example.test/notify" #:return-url "https://example.test/return"
   #:claim-once! (make-sqlite-hosted-replay-claimer replay-path)
   #:clock (lambda () now)))

(define (body offer)
  (jsexpr->bytes (hasheq 'issuer issuer 'offer_id offer 'product_id "publy"
                         'request_id "request_123456789" 'subject_id subject
                         'subject_type "account")))
(define (byte-hex b)
  (define h (string-downcase (format "~x" b)))
  (if (= 1 (string-length h)) (string-append "0" h) h))
(define (headers raw nonce)
  (list (cons "x-commerce-service-id" service-id)
        (cons "x-commerce-timestamp" (number->string now))
        (cons "x-commerce-nonce" nonce)
        (cons "x-commerce-mac"
              (for/fold ([s ""]) ([b (in-bytes
                                      (hosted-request-mac key #:service-id service-id
                                        #:method "POST" #:path "/v1/hosted/alipay-checkout"
                                        #:timestamp now #:nonce nonce #:issuer issuer
                                        #:subject-type "account" #:subject-id subject
                                        #:offer-id offering #:product-id "publy" #:body raw))])
                (string-append s (byte-hex b))))))

(define (call service raw nonce)
  (handle-checkout-http-post service #:method "POST" #:path "/v1/hosted/alipay-checkout"
                             #:body raw #:headers (headers raw nonce) #:now now))

(let ([service (make-service)])
  (define-values (status response) (call service (body offering) "nonce_1234567890123456"))
  (check-equal? status 200)
  (define parsed (bytes->jsexpr response))
  (check-equal? (hash-ref parsed 'status) "checkout-ready")
  (check-equal? (hash-ref parsed 'gateway) "https://openapi-sandbox.dl.alipaydev.com/gateway.do")
  (check-regexp-match #px"^ali[a-f0-9]{32}$" (hash-ref parsed 'order_id))
  ;; the same nonce cannot be replayed
  (define-values (replay-status _) (call service (body offering) "nonce_1234567890123456"))
  (check-equal? replay-status 403)
  ;; a retry with the same request id but a fresh nonce resolves to one order
  (define-values (retry-status retry-response) (call service (body offering) "nonce_abcdefghijklmnop"))
  (check-equal? retry-status 200)
  (check-equal? (hash-ref (bytes->jsexpr retry-response) 'order_id)
                (hash-ref parsed 'order_id))
  ;; unadmitted offer is refused before any binding
  (define-values (bad-status _b) (call service (body "other-offer") "nonce_abcdefghijklmnop"))
  (check-equal? bad-status 403))

(storage-close storage)
(delete-directory/files dir #:must-exist? #f)
