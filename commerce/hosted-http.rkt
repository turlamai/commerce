#lang racket/base

;; Separate, opt-in HTTP surface for the authenticated hosted Permit proof.
;; Does not share the public payment webhook listener or an issuer secret.
(provide hosted-proof-http-endpoint?
         make-hosted-proof-http-endpoint
         handle-hosted-proof-http-post
         serve-hosted-proof-http-endpoint)

(require json
         net/url
         racket/list
         racket/string
         permit/private/json
         permit/trust
         web-server/http
         web-server/servlet-env
         "hosted-auth.rkt"
         "hosted-proof.rkt"
         "storage.rkt"
         "private/time.rkt")

(define proof-path "/v1/hosted/proof")
(define required-fields
  '(expected_entitlement_id issuer minimum_revision offer_id product_id
    subject_id subject_type))

(struct hosted-proof-http-endpoint
  (storage trust-store resolve-key allow-scope claim-once! clock)
  #:transparent)

(define (make-hosted-proof-http-endpoint
         #:storage storage #:trust-store trust-store
         #:resolve-key resolve-key #:allow-scope allow-scope
         #:claim-once! claim-once!
         #:clock [clock current-seconds])
  (unless (commerce-storage? storage)
    (raise-argument-error 'make-hosted-proof-http-endpoint
                          "commerce-storage?" storage))
  (unless (trust-store? trust-store)
    (raise-argument-error 'make-hosted-proof-http-endpoint
                          "trust-store?" trust-store))
  (unless (and (procedure-arity-includes? resolve-key 1)
               (procedure-arity-includes? allow-scope 6)
               (procedure-arity-includes? claim-once! 3)
               (procedure-arity-includes? clock 0))
    (raise-argument-error 'make-hosted-proof-http-endpoint
                          "valid service key, policy, nonce and clock procedures"
                          (list resolve-key allow-scope claim-once! clock)))
  (hosted-proof-http-endpoint
   storage trust-store resolve-key allow-scope claim-once! clock))

(define (json-reply status body)
  (values status (jsexpr->bytes body)))

(define (parse-proof-body raw-body)
  (unless (and (bytes? raw-body) (<= (bytes-length raw-body) 1048576))
    (error 'parse-proof-body "invalid body length"))
  ;; Permit's strict scanner rejects duplicate JSON keys, malformed UTF-8
  ;; and trailing content. Raw bytes are what the HTTP MAC authenticates.
  (define input (read-json-bytes/strict 'parse-proof-body raw-body))
  (unless (and (hash? input)
               (equal? (sort (hash-keys input) symbol<?) required-fields))
    (error 'parse-proof-body "unexpected request fields"))
  (for ([field (in-list '(issuer subject_type subject_id offer_id product_id))])
    (let ([value (hash-ref input field)])
      (unless (and (string? value) (<= 1 (string-length value) 256))
        (error 'parse-proof-body "invalid scope identifier"))))
  (let ([minimum (hash-ref input 'minimum_revision)]
        [expected (hash-ref input 'expected_entitlement_id)])
    (unless (or (eq? minimum 'null) (exact-nonnegative-integer? minimum))
      (error 'parse-proof-body "invalid revision"))
    (unless (or (eq? expected 'null)
                (and (string? expected) (<= 1 (string-length expected) 256)))
      (error 'parse-proof-body "invalid entitlement identity")))
  input)

(define (hex-nibble c)
  (cond [(char<=? #\0 c #\9) (- (char->integer c) 48)]
        [(char<=? #\a c #\f) (- (char->integer c) 87)]
        [else #f]))

(define (parse-mac hex)
  (and (string? hex)
       (= (string-length hex) 64)
       (for/and ([c (in-string hex)]) (hex-nibble c))
       (apply bytes
              (for/list ([i (in-range 0 64 2)])
                (+ (* 16 (hex-nibble (string-ref hex i)))
                   (hex-nibble (string-ref hex (add1 i))))))))

(define (parse-timestamp value)
  (and (string? value)
       (regexp-match? #px"^(0|[1-9][0-9]{0,15})$" value)
       (string->number value)))

(define (handle-hosted-proof-http-post endpoint
                                      #:method method #:path path
                                      #:body raw-body
                                      #:service-id service-id
                                      #:timestamp timestamp
                                      #:nonce nonce
                                      #:mac-hex mac-hex)
  (unless (hosted-proof-http-endpoint? endpoint)
    (raise-argument-error 'handle-hosted-proof-http-post
                          "hosted-proof-http-endpoint?" endpoint))
  (cond
    [(not (and (equal? method "POST") (equal? path proof-path)))
     (json-reply 404 (hasheq 'error "not-found"))]
    [else
     (let ([request
            (with-handlers ([exn:fail? (lambda (_) #f)])
              (parse-proof-body raw-body))])
       (cond
         [(not request)
          (json-reply 400 (hasheq 'error "invalid-request"))]
         [else
          (let* ([issuer (hash-ref request 'issuer)]
                 [subject-type (hash-ref request 'subject_type)]
                 [subject-id (hash-ref request 'subject_id)]
                 [offer-id (hash-ref request 'offer_id)]
                 [product-id (hash-ref request 'product_id)]
                 [now ((hosted-proof-http-endpoint-clock endpoint))]
                 [mac (parse-mac mac-hex)]
                 [signed-at (parse-timestamp timestamp)]
                 [authenticated?
                  (and mac signed-at
                       (verify-hosted-service-request
                        #:service-id service-id
                        #:method method #:path path
                        #:timestamp signed-at #:nonce nonce
                        #:issuer issuer #:subject-type subject-type
                        #:subject-id subject-id #:offer-id offer-id
                        #:product-id product-id #:body raw-body #:mac mac
                        #:resolve-key
                        (hosted-proof-http-endpoint-resolve-key endpoint)
                        #:allow-scope
                        (hosted-proof-http-endpoint-allow-scope endpoint)
                        #:claim-once!
                        (hosted-proof-http-endpoint-claim-once! endpoint)
                        #:now now))])
            (if (not authenticated?)
                (json-reply 401 (hasheq 'error "unauthenticated"))
                (with-handlers
                    ([exn:fail?
                      (lambda (_)
                        (json-reply 503 (hasheq 'error "proof-unavailable")))])
                  (let ([snapshot
                         (current-verified-entitlement-proof
                          (hosted-proof-http-endpoint-storage endpoint)
                          #:issuer issuer #:subject-type subject-type
                          #:subject-id subject-id #:offer-id offer-id
                          #:product-id product-id
                          ;; Authenticated request already passed a trusted
                          ;; service+full-scope allowlist before DB access.
                          #:authorize
                          (lambda (i t s o p)
                            (and (equal? i issuer) (equal? t subject-type)
                                 (equal? s subject-id) (equal? o offer-id)
                                 (equal? p product-id)))
                          #:trust-store
                          (hosted-proof-http-endpoint-trust-store endpoint)
                          #:at (epoch-seconds->rfc3339 now)
                          #:minimum-revision
                          (let ([v (hash-ref request 'minimum_revision)])
                            (if (eq? v 'null) #f v))
                          #:expected-entitlement-id
                          (let ([v (hash-ref request 'expected_entitlement_id)])
                            (if (eq? v 'null) #f v)))])
                    (json-reply 200 snapshot)))))]))]))

(define (unique-header headers field)
  (define matches
    (filter (lambda (header)
              (string-ci=? (bytes->string/utf-8 (header-field header))
                           field))
            headers))
  (and (= (length matches) 1)
       (bytes->string/utf-8 (header-value (car matches)))))

;; Dedicated listener; reverse proxy must provide TLS and limit access to
;; registered service clients. No issuer private key is loaded here.
(define (serve-hosted-proof-http-endpoint endpoint
                                          #:port port
                                          #:listen-ip [listen-ip "127.0.0.1"])
  (define owner (make-custodian))
  (parameterize ([current-custodian owner])
    (serve/servlet
     (lambda (request)
       (define headers (request-headers/raw request))
       (define path (url->string (request-uri request)))
       (define-values (status body)
         (handle-hosted-proof-http-post
          endpoint
          #:method (bytes->string/utf-8 (request-method request))
          #:path path
          #:body (or (request-post-data/raw request) #"")
          #:service-id (unique-header headers "x-commerce-service-id")
          #:timestamp (unique-header headers "x-commerce-timestamp")
          #:nonce (unique-header headers "x-commerce-nonce")
          #:mac-hex (unique-header headers "x-commerce-mac")))
       (response/full status #"commerce-hosted" (current-seconds)
                      #"application/json" '() (list body)))
     #:port port #:listen-ip listen-ip #:command-line? #f
     #:servlet-path proof-path
     #:servlet-regexp #rx"^/v1/hosted/proof$"))
  (lambda () (custodian-shutdown-all owner)))
