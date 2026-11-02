#lang racket/base

(require rackunit
         json
         file/sha1
         racket/file
         permit/issuer
         commerce/hosted-auth
         commerce/hosted-http
         commerce/hosted-replay/sqlite
         (only-in commerce/storage storage-close)
         commerce/storage/sqlite)

(define-values (_private-key public-key) (generate-ed25519-keypair))
(define trust
  (jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1 'issuer "com.turinglambdaai"
           'keys
           (hasheq 'test-2026
                   (hasheq 'algorithm "Ed25519"
                           'public_key (public-key->base64 public-key)
                           'status "active"
                           'purposes '("entitlement")
                           'not_before 'null 'not_after 'null)))))
(define key (make-bytes 32 77))
(define body
  (jsexpr->bytes
   (hasheq 'issuer "com.turinglambdaai"
           'subject_type "account"
           'subject_id "customer-a"
           'offer_id "taskly-pro-lifetime"
           'product_id "taskly"
           'minimum_revision 'null
           'expected_entitlement_id 'null)))

(define (with-endpoint proc)
  (define dir (make-temporary-file "commerce-hosted-http-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage
       (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
     (define nonce-db (build-path dir "nonces.sqlite"))
     (initialize-sqlite-hosted-replay-store! nonce-db)
     (let ([endpoint
       (make-hosted-proof-http-endpoint
        #:storage storage #:trust-store trust
        #:resolve-key
        (lambda (service)
          (and (equal? service "publy-backend") key))
        #:allow-scope
        (lambda (service issuer type subject offer product)
          (and (equal? service "publy-backend")
               (equal? issuer "com.turinglambdaai")
               (equal? type "account")
               (equal? subject "customer-a")
               (equal? offer "taskly-pro-lifetime")
               (equal? product "taskly")))
        #:claim-once!
        (make-sqlite-hosted-replay-claimer
         nonce-db #:now (lambda () 1000))
        #:clock (lambda () 1000))])
       (dynamic-wind void (lambda () (proc endpoint))
                     (lambda () (storage-close storage)))))
   (lambda () (delete-directory/files dir))))

(define (submit endpoint
                #:body [raw body]
                #:method [method "POST"]
                #:path [path "/v1/hosted/proof"]
                #:nonce [nonce "unique_nonce_value_001"]
                #:mac [mac #f]
                #:service [service "publy-backend"]
                #:timestamp [timestamp "1000"])
  (define signature
    (or mac
        (bytes->hex-string
         (hosted-request-mac
          key #:service-id "publy-backend"
          #:method "POST" #:path "/v1/hosted/proof"
          #:timestamp 1000 #:nonce nonce
          #:issuer "com.turinglambdaai"
          #:subject-type "account"
          #:subject-id "customer-a"
          #:offer-id "taskly-pro-lifetime"
          #:product-id "taskly"
          #:body body))))
  (define-values (status result)
    (handle-hosted-proof-http-post
     endpoint #:method method #:path path #:body raw
     #:service-id service #:timestamp timestamp
     #:nonce nonce #:mac-hex signature))
  (values status (bytes->jsexpr result)))

(test-case "authenticated HTTP proof returns absent, refuses replay"
  (with-endpoint
   (lambda (endpoint)
     (define-values (status first) (submit endpoint))
     (define-values (second-status second) (submit endpoint))
     (check-equal? status 200)
     (check-equal? (hash-ref first 'status) "absent")
     (check-equal? second-status 401)
     (check-equal? (hash-ref second 'error) "unauthenticated"))))

(test-case "raw signed body and service headers cannot be substituted"
  (with-endpoint
   (lambda (endpoint)
     (define-values (tampered-status _tampered)
       (submit endpoint #:body #"{\"subject_id\":\"customer-b\"}"))
     (define-values (method-status _method)
       (submit endpoint #:method "GET"))
     (define-values (path-status _path)
       (submit endpoint #:path "/v1/hosted/proof?anything=yes"))
     (define-values (key-status _key)
       (submit endpoint #:service "other-backend"))
     (define-values (mac-status _mac)
       (submit endpoint #:mac (make-string 64 #\0)))
     (define-values (clock-status _clock)
       (submit endpoint #:timestamp "1301"))
     (check-equal? tampered-status 400)
     (check-equal? method-status 404)
     (check-equal? path-status 404)
     (check-equal? key-status 401)
     (check-equal? mac-status 401)
     (check-equal? clock-status 401))))

(test-case "duplicate JSON member, new fields and malformed bodies deny"
  (with-endpoint
   (lambda (endpoint)
     (define duplicate #"{\"issuer\":\"com.turinglambdaai\",\"issuer\":\"other\"}")
     (define extra
       (bytes-append (subbytes body 0 (sub1 (bytes-length body)))
                     #",\"paid\":true}"))
     (define-values (dup-status _dup) (submit endpoint #:body duplicate))
     (define-values (extra-status _extra) (submit endpoint #:body extra))
     (define-values (invalid-status _invalid)
       (submit endpoint #:body #"not json"))
     (check-equal? dup-status 400)
     (check-equal? extra-status 400)
     (check-equal? invalid-status 400))))

(test-case "signed request with previously observed revision denies stale replica"
  (with-endpoint
   (lambda (endpoint)
     (define revised
       (jsexpr->bytes
        (hasheq 'issuer "com.turinglambdaai"
                'subject_type "account" 'subject_id "customer-a"
                'offer_id "taskly-pro-lifetime" 'product_id "taskly"
                'minimum_revision 1
                'expected_entitlement_id 'null)))
     (define signed
       (bytes->hex-string
        (hosted-request-mac
         key #:service-id "publy-backend"
         #:method "POST" #:path "/v1/hosted/proof"
         #:timestamp 1000 #:nonce "unique_nonce_value_002"
         #:issuer "com.turinglambdaai" #:subject-type "account"
         #:subject-id "customer-a" #:offer-id "taskly-pro-lifetime"
         #:product-id "taskly" #:body revised)))
     (define-values (status response)
       (submit endpoint #:body revised #:mac signed
               #:nonce "unique_nonce_value_002"))
     (check-equal? status 200)
     (check-equal? (hash-ref response 'status) "stale-revision"))))

(test-case "well-formed tampering and a freshly signed forbidden account deny"
  (with-endpoint
   (lambda (endpoint)
     (define unauthorized-body
       (jsexpr->bytes
        (hash-set (bytes->jsexpr body) 'subject_id "customer-b")))
     ;; Malicious proxy changes the exact raw body but cannot forge HMAC.
     (define-values (tampered-status _tampered)
       (submit endpoint #:body unauthorized-body
               #:nonce "unique_nonce_value_003"))
     ;; Even a signer that holds the S2S key has no authority for another
     ;; account unless the server-side service registry permits that scope.
     (define signed-forbidden
       (bytes->hex-string
        (hosted-request-mac
         key #:service-id "publy-backend"
         #:method "POST" #:path "/v1/hosted/proof"
         #:timestamp 1000 #:nonce "unique_nonce_value_004"
         #:issuer "com.turinglambdaai" #:subject-type "account"
         #:subject-id "customer-b" #:offer-id "taskly-pro-lifetime"
         #:product-id "taskly" #:body unauthorized-body)))
     (define-values (forbidden-status _forbidden)
       (submit endpoint #:body unauthorized-body #:mac signed-forbidden
               #:nonce "unique_nonce_value_004"))
     (check-equal? tampered-status 401)
     (check-equal? forbidden-status 401))))
