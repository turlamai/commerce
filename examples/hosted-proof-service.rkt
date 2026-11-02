#lang racket/base

;; Local-only operator entrypoint for a distinct hosted Permit proof listener.
;; No Permit signing key, payment webhook secret or demo paid Offer is loaded.
;; Explicitly provision the nonce DB before starting (docs/hosted-proof-http.md).

(module+ main
  (require commerce/hosted-http
           commerce/hosted-registry
           commerce/hosted-replay/sqlite
           (only-in commerce/storage storage-close)
           commerce/storage/sqlite
           permit/trust
           racket/file)

  (define (required name)
    (define value (getenv name))
    (unless (and value (positive? (string-length value)))
      (error 'hosted-proof-service "missing required environment setting: ~a"
             name))
    value)

  (define (existing path name)
    (unless (file-exists? path)
      (error 'hosted-proof-service "~a file is not present" name))
    path)

  (define (port-from-env)
    (define value
      (string->number (required "COMMERCE_HOSTED_PORT")))
    (unless (and (exact-integer? value) (<= 1 value 65535))
      (error 'hosted-proof-service
             "COMMERCE_HOSTED_PORT must be a TCP port 1-65535"))
    value)

  (define db-path
    (existing (required "COMMERCE_HOSTED_DB_PATH") "Commerce ledger"))
  (define nonce-path
    (existing (required "COMMERCE_HOSTED_NONCE_DB_PATH") "nonce replay"))
  (define registry-path
    (existing (required "COMMERCE_HOSTED_REGISTRY_PATH") "service registry"))
  (define trust-path
    (existing (required "COMMERCE_HOSTED_TRUST_STORE_PATH") "Permit trust store"))
  (define port (port-from-env))

  (define registry (read-hosted-service-registry registry-path))
  (define trust-store (read-trust-store trust-path))
  (define replay-claimer (make-sqlite-hosted-replay-claimer nonce-path))
  (define storage (open-sqlite-commerce-storage db-path))

  (define endpoint
    (make-hosted-proof-http-endpoint
     #:storage storage
     #:trust-store trust-store
     #:resolve-key
     (lambda (id)
       (hosted-service-registry-resolve-key registry id))
     #:allow-scope
     (lambda (service issuer type subject offer product)
       (hosted-service-registry-allow-scope
        registry service issuer type subject offer product))
     #:claim-once! replay-claimer))

  (define stop
    (serve-hosted-proof-http-endpoint
     endpoint #:port port #:listen-ip "127.0.0.1"))

  (dynamic-wind
   void
   (lambda ()
     (printf "Commerce hosted Permit proof endpoint active on loopback port ~a\n"
             port)
     (flush-output)
     (sync (make-semaphore)))
   (lambda ()
     (stop)
     (storage-close storage))))
