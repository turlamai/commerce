#lang racket/base

;; Explicit, operator-controlled S2S key + scope registry.
;; No wildcard subjects, products or Offers, and no inline key material.
(provide hosted-service-registry?
         read-hosted-service-registry
         hosted-service-registry-resolve-key
         hosted-service-registry-allow-scope)

(require racket/file
         racket/list
         permit/private/json)

(struct hosted-service-registry (keys scopes) #:transparent)

(define (exact-keys? value names)
  (and (hash? value)
       (equal? (sort (hash-keys value) symbol<?) names)))

(define (bounded-id? value)
  (and (string? value) (<= 1 (string-length value) 256)))

(define scope-fields
  '(issuer offer_id product_id subject_id subject_type))
(define service-fields '(id key_file scopes))

(define (parse-scope scope)
  (unless (exact-keys? scope scope-fields)
    (error 'read-hosted-service-registry "invalid service scope schema"))
  (for ([field (in-list scope-fields)])
    (unless (bounded-id? (hash-ref scope field))
      (error 'read-hosted-service-registry "invalid scoped identifier")))
  (for/list ([field (in-list scope-fields)])
    (hash-ref scope field)))

(define (parse-entry entry)
  (unless (exact-keys? entry service-fields)
    (error 'read-hosted-service-registry "invalid service registry schema"))
  (define service-id (hash-ref entry 'id))
  (define key-file (hash-ref entry 'key_file))
  (define raw-scopes (hash-ref entry 'scopes))
  (unless (bounded-id? service-id)
    (error 'read-hosted-service-registry "invalid service identifier"))
  (unless (and (string? key-file)
               (absolute-path? (string->path key-file)))
    (error 'read-hosted-service-registry
           "service key_file must be an absolute filesystem path"))
  (unless (and (list? raw-scopes)
               (<= 1 (length raw-scopes) 200))
    (error 'read-hosted-service-registry
           "each service must have 1-200 explicit scopes"))
  (define key (file->bytes key-file))
  (unless (<= 32 (bytes-length key) 128)
    (error 'read-hosted-service-registry
           "service HMAC key must contain 32-128 random raw bytes"))
  (values service-id (bytes->immutable-bytes key)
          (for/list ([scope (in-list raw-scopes)])
            (parse-scope scope))))

(define (read-hosted-service-registry path)
  (unless (path-string? path)
    (raise-argument-error 'read-hosted-service-registry "path-string?" path))
  (define document
    (read-json-bytes/strict
     'read-hosted-service-registry (file->bytes path)))
  (unless (exact-keys? document '(services version))
    (error 'read-hosted-service-registry "invalid root registry schema"))
  (unless (equal? (hash-ref document 'version) 1)
    (error 'read-hosted-service-registry "unsupported registry version"))
  (define services (hash-ref document 'services))
  (unless (and (list? services) (<= 1 (length services) 100))
    (error 'read-hosted-service-registry
           "service registry must contain 1-100 services"))
  (define keys (make-hash))
  (define scopes (make-hash))
  (for ([entry (in-list services)])
    (let-values ([(id key authorized) (parse-entry entry)])
      (when (hash-has-key? keys id)
        (error 'read-hosted-service-registry "duplicate service identifier"))
      (hash-set! keys id key)
      (hash-set! scopes id authorized)))
  (hosted-service-registry (make-immutable-hash (hash->list keys))
                           (make-immutable-hash (hash->list scopes))))

(define (hosted-service-registry-resolve-key registry service-id)
  (unless (hosted-service-registry? registry)
    (raise-argument-error 'hosted-service-registry-resolve-key
                          "hosted-service-registry?" registry))
  (hash-ref (hosted-service-registry-keys registry) service-id #f))

(define (hosted-service-registry-allow-scope
         registry service-id issuer subject-type subject-id offer-id product-id)
  (unless (hosted-service-registry? registry)
    (raise-argument-error 'hosted-service-registry-allow-scope
                          "hosted-service-registry?" registry))
  (define target (list issuer offer-id product-id subject-id subject-type))
  (and (list? (hash-ref (hosted-service-registry-scopes registry)
                        service-id #f))
       (if (member target
                   (hash-ref (hosted-service-registry-scopes registry)
                             service-id '()))
           #t #f)))
