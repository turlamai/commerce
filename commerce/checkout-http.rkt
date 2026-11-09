#lang racket/base

;; Authenticated hosted checkout edge. A product service signs the exact
;; request; this edge verifies it, re-checks the private ADR-0019 admission,
;; binds the order durably before signing Alipay page-pay fields, and returns
;; only the signed browser form. It never returns a merchant private key.

(provide checkout-http-service?
         make-checkout-http-service
         handle-checkout-http-post)

(require crypto
         crypto/libcrypto
         crypto/pem
         json
         net/url
         racket/file
         racket/list
         racket/port
         racket/string
         (except-in file/sha1 bytes->hex-string)
         permit/private/json
         web-server/http
         web-server/servlet-env
         "admission.rkt"
         "alipay.rkt"
         "hosted-auth.rkt"
         "hosted-replay/sqlite.rkt"
         "private/alipay-time.rkt"
         "private/model.rkt"
         "storage.rkt"
         "storage/sqlite.rkt")

(define checkout-path "/v1/hosted/alipay-checkout")
(define required-fields '(issuer offer_id product_id request_id subject_id subject_type))

(struct checkout-http-service
  (admission admission-json storage signer service-id service-key issuer app-id seller-id
             gateway notify-url return-url claim-once! clock)
  #:transparent)

(define (read-json-file path)
  (read-json-bytes/strict 'read-json-file (file->bytes path)))

(define (admission-capability admission-json offer-id product-id)
  (define caps (hash-ref admission-json 'capabilities))
  (for/first ([cap (in-list caps)]
              #:when (and (equal? (hash-ref cap 'offer_id) offer-id)
                          (equal? (hash-ref cap 'product_id) product-id)
                          (equal? (hash-ref cap 'method) "alipay")
                          (equal? (hash-ref cap 'transaction_type) "one-time")
                          (equal? (hash-ref cap 'currency) "CNY")))
    cap))

(define (make-checkout-http-service
         #:admission admission #:admission-json admission-json
         #:storage storage #:signer signer
         #:service-id service-id #:service-key service-key #:issuer issuer
         #:app-id app-id #:seller-id seller-id #:gateway gateway
         #:notify-url notify-url #:return-url return-url
         #:claim-once! claim-once! #:clock [clock current-seconds])
  (unless (and (provider-admission? admission) (hash? admission-json)
               (commerce-storage? storage) (procedure? signer)
               (string? service-id) (bytes? service-key)
               (string? issuer) (string? app-id) (string? seller-id)
               (string? gateway) (string? notify-url) (string? return-url)
               (procedure? claim-once!) (procedure? clock))
    (raise-argument-error 'make-checkout-http-service "valid checkout service inputs" #f))
  (checkout-http-service admission admission-json storage signer service-id service-key issuer
                         app-id seller-id gateway notify-url return-url claim-once! clock))

(define (parse-checkout-body raw)
  (unless (and (bytes? raw) (<= 1 (bytes-length raw) 1048576))
    (error 'checkout-body "invalid body length"))
  (define input (read-json-bytes/strict 'checkout-body raw))
  (unless (and (hash? input)
               (equal? (sort (hash-keys input) symbol<?) (sort required-fields symbol<?)))
    (error 'checkout-body "unexpected request fields"))
  (for ([field (in-list '(issuer offer_id product_id subject_id subject_type))])
    (define value (hash-ref input field))
    (unless (and (string? value) (<= 1 (string-length value) 256))
      (error 'checkout-body "invalid scope identifier")))
  (define request-id (hash-ref input 'request_id))
  (unless (and (string? request-id) (regexp-match? #px"^[A-Za-z0-9_-]{16,128}$" request-id))
    (error 'checkout-body "invalid request id"))
  input)

(define (header headers name)
  (define value (assoc name headers))
  (and value (cdr value)))

(define (json-status status body)
  (values status (jsexpr->bytes body)))

(define (deny)
  (json-status 403 (hasheq 'code "CHECKOUT_FORBIDDEN")))

;; request-headers: exact list of (lowercase-name . value) pairs.
(define (handle-checkout-http-post service
                                   #:method method #:path path #:body raw
                                   #:headers headers #:now now)
  (unless (checkout-http-service? service)
    (raise-argument-error 'handle-checkout-http-post "checkout-http-service?" service))
  (with-handlers ([exn:fail? (lambda (_) (deny))])
    (define input (parse-checkout-body raw))
    (define request-id (hash-ref input 'request_id))
    (define issuer (hash-ref input 'issuer))
    (define offer-id (hash-ref input 'offer_id))
    (define product-id (hash-ref input 'product_id))
    (define subject-id (hash-ref input 'subject_id))
    (define subject-type (hash-ref input 'subject_type))
    (unless (and (equal? method "POST") (equal? path checkout-path)
                 (equal? issuer (checkout-http-service-issuer service))
                 (equal? product-id "publy") (equal? subject-type "account"))
      (error 'checkout-http "denied"))
    (define cap (admission-capability (checkout-http-service-admission-json service) offer-id product-id))
    (unless cap (error 'checkout-http "denied"))
    (define amount (hash-ref cap 'amount_minor))
    (define key (checkout-http-service-service-key service))
    (define request-ok
      (verify-hosted-service-request
       #:service-id (checkout-http-service-service-id service)
       #:method method #:path path
       #:timestamp (string->number (or (header headers "x-commerce-timestamp") ""))
       #:nonce (or (header headers "x-commerce-nonce") "")
       #:issuer issuer #:subject-type subject-type #:subject-id subject-id
       #:offer-id offer-id #:product-id product-id #:body raw
       #:mac (hex->bytes (or (header headers "x-commerce-mac") ""))
       #:resolve-key (lambda (service-id)
                       (and (equal? service-id (checkout-http-service-service-id service)) key))
       #:allow-scope (lambda (service-id issuer* subject-type* subject-id* offer-id* product-id*)
                       (and (equal? service-id (checkout-http-service-service-id service))
                            (equal? issuer* issuer) (equal? subject-type* "account")
                            (equal? subject-id* subject-id) (equal? offer-id* offer-id)
                            (equal? product-id* "publy") #t))
       #:claim-once! (checkout-http-service-claim-once! service)
       #:now now))
    (unless request-ok (error 'checkout-http "denied"))
    (authorize-provider-checkout!
     (checkout-http-service-admission service)
     #:provider "alipay"
     #:environment (if (string-contains? (checkout-http-service-gateway service) "sandbox") "sandbox" "production")
     #:merchant-app-id (checkout-http-service-app-id service)
     #:seller-id (checkout-http-service-seller-id service)
     #:product-id product-id #:offer-id offer-id #:payment-method "alipay"
     #:transaction-type "one-time" #:amount (money "CNY" amount) #:at now)
    ;; A retry with the same product request id must resolve to the same
    ;; merchant order; deriving the order id from request_id prevents a
    ;; duplicate checkout when the first response was lost.
    (define order-id
      (string-append "ali"
                     (substring (bytes->hex-string
                                 (sha256-bytes (string->bytes/utf-8
                                          (format "~a\0~a\0~a" subject-id offer-id request-id))))
                                0 32)))
    (define existing (storage-checkout-binding-ref (checkout-http-service-storage service) order-id))
    (when existing
      (unless (and (equal? (checkout-binding-provider existing) "alipay")
                   (equal? (checkout-binding-product-id existing) product-id)
                   (equal? (checkout-binding-offer-id existing) offer-id)
                   (equal? (checkout-binding-subject-id existing) subject-id)
                   (equal? (checkout-binding-currency existing) "CNY")
                   (= (checkout-binding-amount-minor-units existing) amount))
        (error 'checkout-body "request id bound to different checkout")))
    (unless existing
      (storage-create-checkout-binding!
       (checkout-http-service-storage service)
       (checkout-binding order-id "alipay" product-id offer-id subject-id "CNY" amount 2)
       #:created-at now))
    (define binding
      (alipay-binding (checkout-http-service-app-id service) (checkout-http-service-seller-id service)
                      order-id offer-id subject-id (money "CNY" amount)))
    (define fields ((checkout-http-service-signer service) binding))
    (unless (and (list? fields) (<= 1 (length fields) 32)
                 (for/and ([p (in-list fields)])
                   (and (pair? p) (string? (car p)) (string? (cdr p)))))
      (error 'checkout-body "invalid signed fields"))
    (json-status 200
                 (hasheq 'status "checkout-ready" 'order_id order-id
                         'gateway (checkout-http-service-gateway service)
                         'fields (for/hash ([p (in-list fields)])
                                   (values (string->symbol (car p)) (cdr p)))))))

(define (hex->bytes text)
  (and (string? text) (regexp-match? #px"^[a-f0-9]{64}$" text)
       (for/fold ([out #""]) ([i (in-range 0 64 2)])
         (bytes-append out (bytes (string->number (substring text i (+ i 2)) 16))))))

(define (unique-header headers name)
  (define found (filter (lambda (p) (equal? (car p) name)) headers))
  (and (= (length found) 1) (cdr (car found))))

;; Production entrypoint. Secrets are file paths read once; TLS and ingress
;; filtering remain the reverse proxy's responsibility.
(module+ main
  (define (required name)
    (define value (getenv name))
    (unless (and value (not (string=? value "")))
      (error 'checkout-http-service "missing environment setting" name))
    value)
  (define (merchant-key path)
    (define entry
      (call-with-input-string
       (string-replace (file->string path) "\r\n" "\n")
       (lambda (in) (read-pem in #:only (list #"PRIVATE KEY" #"RSA PRIVATE KEY")))))
    (unless (pair? entry) (error 'checkout-http-service "merchant key invalid"))
    (define format (if (bytes=? (car entry) #"PRIVATE KEY") 'OneAsymmetricKey 'RSAPrivateKey))
    (define key (datum->pk-key (cdr entry) format (list libcrypto-factory)))
    (unless (private-key? key) (error 'checkout-http-service "merchant key not private"))
    key)
  (define admission (read-provider-admission (required "COMMERCE_PROVIDER_ADMISSION_PATH")))
  (define admission-json (read-json-file (required "COMMERCE_PROVIDER_ADMISSION_PATH")))
  (define gateway (case (string->symbol (required "ALIPAY_ENV"))
                    [(sandbox) "https://openapi-sandbox.dl.alipaydev.com/gateway.do"]
                    [(production) "https://openapi.alipay.com/gateway.do"]
                    [else (error 'checkout-http-service "invalid ALIPAY_ENV")]))
  (define app-id (required "ALIPAY_APP_ID"))
  (define seller-id (required "ALIPAY_SELLER_ID"))
  (define private-key (merchant-key (required "ALIPAY_PRIVATE_KEY_PATH")))
  (define storage (open-sqlite-commerce-storage (required "COMMERCE_DATABASE_PATH")))
  (define replay-path (required "COMMERCE_REPLAY_DB_PATH"))
  (initialize-sqlite-hosted-replay-store! replay-path)
  (define service
    (make-checkout-http-service
     #:admission admission #:admission-json admission-json
     #:storage storage
     #:signer (lambda (binding)
                (make-alipay-page-pay-parameters binding private-key
                  #:title (alipay-binding-offer-id binding)
                  #:notify-url (required "ALIPAY_NOTIFY_URL")
                  #:return-url (required "ALIPAY_RETURN_URL")
                  #:timestamp (epoch-seconds->gmt8-timestamp (current-seconds))))
     #:service-id (required "COMMERCE_SERVICE_ID")
     #:service-key (file->bytes (required "COMMERCE_SERVICE_HMAC_PATH"))
     #:issuer (required "COMMERCE_ISSUER")
     #:app-id app-id #:seller-id seller-id #:gateway gateway
     #:notify-url (required "ALIPAY_NOTIFY_URL") #:return-url (required "ALIPAY_RETURN_URL")
     #:claim-once! (make-sqlite-hosted-replay-claimer replay-path)
     #:clock current-seconds))
  (define port (string->number (required "COMMERCE_HTTP_PORT")))
  (define owner (make-custodian))
  (parameterize ([current-custodian owner])
    (serve/servlet
     (lambda (request)
       (define path (url->string (request-uri request)))
       (cond
         [(equal? path "/health")
          (response/full 200 #"ok" (current-seconds) #"text/plain" '() (list #"ok"))]
         [(equal? path checkout-path)
          (define headers
            (for/list ([h (in-list (request-headers/raw request))])
              (cons (string-downcase (bytes->string/utf-8 (header-field h)))
                    (bytes->string/utf-8 (header-value h)))))
          (define-values (status body)
            (handle-checkout-http-post service
              #:method (bytes->string/utf-8 (request-method request))
              #:path path #:body (or (request-post-data/raw request) #"")
              #:headers headers #:now (current-seconds)))
          (response/full status #"commerce-checkout" (current-seconds)
                         #"application/json" '() (list body))]
         [else (response/full 404 #"not found" (current-seconds) #"text/plain" '() (list #"not found"))]))
     #:port port #:listen-ip "127.0.0.1" #:command-line? #f #:servlet-path "/"
     #:servlet-regexp #rx"^/(health|v1/hosted/alipay-checkout)$"))
  (void))
