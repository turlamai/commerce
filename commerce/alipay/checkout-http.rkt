#lang racket/base

;; Dedicated opt-in loopback listener; never deploy without TLS and access controls.
;; The private key is retained in an opaque struct and never in responses.
(provide make-alipay-checkout-http-endpoint handle-alipay-checkout-http-post
         serve-alipay-checkout-http-endpoint)

(require json racket/list racket/string net/url web-server/http web-server/servlet-env
         permit/private/json
         "../main.rkt" "../storage.rkt" "../hosted-auth.rkt"
         "../private/model.rkt" "../private/alipay-time.rkt"
         "checkout-coordinator.rkt")

(define route "/v1/hosted/alipay-checkout")
(define required-fields '(issuer offer_id product_id request_id subject_id subject_type))
(struct endpoint (storage resolve-key allow-scope claim-once! checkout-claim! resolve-offer
                          title admission environment app seller private-key notify return clock))

(define (make-alipay-checkout-http-endpoint
         #:storage storage #:resolve-key resolve-key #:allow-scope allow-scope
         #:claim-once! claim-once! #:checkout-claim! checkout-claim! #:resolve-offer resolve-offer
         #:title title #:admission admission #:environment environment #:app-id app #:seller-id seller
         #:private-key private-key #:notify-url notify #:return-url return #:clock [clock current-seconds])
  (unless (and (commerce-storage? storage)
               (procedure-arity-includes? resolve-key 1) (procedure-arity-includes? allow-scope 6)
               (procedure-arity-includes? claim-once! 3) (procedure-arity-includes? checkout-claim! 3)
               (procedure-arity-includes? resolve-offer 2) (procedure-arity-includes? clock 0)
               (member environment '("sandbox" "production")))
    (error 'make-alipay-checkout-http-endpoint "invalid trusted configuration"))
  (endpoint storage resolve-key allow-scope claim-once! checkout-claim! resolve-offer
            title admission environment app seller private-key notify return clock))

(define (reply status obj) (values status (jsexpr->bytes obj)))
(define (parse raw)
  (and (bytes? raw) (<= 1 (bytes-length raw) 16384)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define x (read-json-bytes/strict 'alipay-checkout raw))
         (and (hash? x) (equal? (sort (hash-keys x) symbol<?) required-fields)
              (for/and ([field (in-list required-fields)])
                (define v (hash-ref x field))
                (and (string? v) (<= 1 (string-length v) 256)))
              (equal? (hash-ref x 'subject_type) "account") x))))

(define (mac-bytes s)
  (and (string? s) (regexp-match? #px"^[a-f0-9]{64}$" s)
       (apply bytes (for/list ([i (in-range 0 64 2)]) (string->number (substring s i (+ i 2)) 16)))))

(define (handle-alipay-checkout-http-post e #:method method #:path path #:body body
                                          #:service-id service #:timestamp timestamp #:nonce nonce #:mac-hex mac)
  (unless (endpoint? e) (raise-argument-error 'handle-alipay-checkout-http-post "endpoint?" e))
  (cond
    [(not (and (equal? method "POST") (equal? path route))) (reply 404 (hasheq 'error "not-found"))]
    [else
     (define request (parse body))
     (cond
       [(not request) (reply 400 (hasheq 'error "invalid-request"))]
       [else
        (define signed-at (and (string? timestamp) (regexp-match? #px"^(0|[1-9][0-9]{0,15})$" timestamp) (string->number timestamp)))
        (define now ((endpoint-clock e)))
        (define authenticated?
          (and signed-at (mac-bytes mac)
               (verify-hosted-service-request
                #:service-id service #:method method #:path path #:timestamp signed-at #:nonce nonce
                #:issuer (hash-ref request 'issuer) #:subject-type (hash-ref request 'subject_type)
                #:subject-id (hash-ref request 'subject_id) #:offer-id (hash-ref request 'offer_id)
                #:product-id (hash-ref request 'product_id) #:body body #:mac (mac-bytes mac)
                #:resolve-key (endpoint-resolve-key e) #:allow-scope (endpoint-allow-scope e)
                #:claim-once! (endpoint-claim-once! e) #:now now)))
        (cond
          [(not authenticated?) (reply 401 (hasheq 'error "unauthenticated"))]
          [else
           (with-handlers ([exn:fail:commerce?
                            (lambda (err)
                              (if (eq? (exn:fail:commerce-code err) 'checkout-conflict)
                                  (reply 409 (hasheq 'error "checkout-conflict"))
                                  (reply 503 (hasheq 'error "checkout-unavailable"))))]
                           [exn:fail? (lambda (_) (reply 503 (hasheq 'error "checkout-unavailable")))])
             (define product (hash-ref request 'product_id))
             (define chosen-id (hash-ref request 'offer_id))
             (define subject (hash-ref request 'subject_id))
             (define selected ((endpoint-resolve-offer e) product chosen-id))
             (unless (and (offer? selected) (equal? (offer-product-id selected) product) (equal? (offer-id selected) chosen-id))
               (error 'checkout "no trusted offer"))
             (define-values (order fields)
               (create-alipay-checkout!
                (endpoint-storage e) #:service-id service #:request-id (hash-ref request 'request_id)
                #:subject-id subject #:offer selected
                #:authorize (lambda (s p o u) (and (equal? s service) (equal? p product)
                                                   (equal? o chosen-id) (equal? u subject)))
                #:claim! (endpoint-checkout-claim! e) #:admission (endpoint-admission e)
                #:environment (endpoint-environment e) #:app-id (endpoint-app e) #:seller-id (endpoint-seller e)
                #:private-key (endpoint-private-key e) #:title (endpoint-title e)
                #:notify-url (endpoint-notify e) #:return-url (endpoint-return e)
                #:timestamp (epoch-seconds->gmt8-timestamp now) #:at now))
             (reply 200 (hasheq 'status "checkout-ready" 'order_id order
                                'gateway (if (equal? (endpoint-environment e) "sandbox")
                                             "https://openapi-sandbox.dl.alipaydev.com/gateway.do"
                                             "https://openapi.alipay.com/gateway.do")
                                'fields (for/hasheq ([field (in-list fields)])
                                          (values (string->symbol (car field)) (cdr field))))))])])]))

(define (one-header headers name)
  (define found (filter (lambda (h) (string-ci=? (bytes->string/utf-8 (header-field h)) name)) headers))
  (and (= (length found) 1) (bytes->string/utf-8 (header-value (car found)))))

(define (serve-alipay-checkout-http-endpoint e #:port port)
  (unless (endpoint? e) (raise-argument-error 'serve-alipay-checkout-http-endpoint "endpoint?" e))
  (define owner (make-custodian))
  (parameterize ([current-custodian owner])
    (serve/servlet
     (lambda (request)
       (define headers (request-headers/raw request))
       (define-values (status body)
         (handle-alipay-checkout-http-post
          e #:method (string-upcase (bytes->string/utf-8 (request-method request)))
          #:path (url->string (request-uri request)) #:body (or (request-post-data/raw request) #"")
          #:service-id (one-header headers "x-commerce-service-id")
          #:timestamp (one-header headers "x-commerce-timestamp")
          #:nonce (one-header headers "x-commerce-nonce") #:mac-hex (one-header headers "x-commerce-mac")))
       (response/full status #"commerce-checkout" (current-seconds) #"application/json"
                      (list (header #"cache-control" #"no-store")) (list body)))
     #:port port #:listen-ip "127.0.0.1" #:command-line? #f
     #:servlet-path route #:servlet-regexp #rx"^/v1/hosted/alipay-checkout$"))
  (lambda () (custodian-shutdown-all owner)))
