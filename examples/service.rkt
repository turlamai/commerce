#lang racket/base

;; Role-selectable assembly of the HTTP edge and the signing/projector worker.
;; Edge and issuer may run as different OS users over the same SQLite store.
;; Splitting role processes removes raw Permit key access from the web process
;; but does not make their shared writable database a trusted signing boundary.
;;
;; Run it only after reading docs/runbook.md and deploy/README.md. The
;; catalog below is a placeholder: replace it with your product's
;; reviewed, version-pinned policy before accepting real payments.
;;
;; Termination: SIGTERM/SIGKILL is crash-safe by design (WAL +
;; synchronous=FULL; a restart re-claims expired leases and re-projects
;; from the immutable journal). A clean shutdown posts the stop
;; semaphore and closes the store.

(module+ main
  (require commerce
           commerce/evidence
           commerce/health
           commerce/issuer
           commerce/pancake
           commerce/private/service-role
           commerce/permit
           commerce/server
           commerce/storage
           commerce/storage/sqlite
           permit/issuer
           racket/file
           racket/match
           racket/string)

  ;; ---- configuration -------------------------------------------------

  (define (env name [default #f])
    (define value (getenv name))
    (if (and value (not (string=? value ""))) value default))

  (define (env-require name)
    (or (env name)
        (begin
          (eprintf "missing required environment variable ~a\n" name)
          (exit 1))))

  (define (env-number name default)
    (define value (env name))
    (if value (string->number value) default))

  (define role
    (with-handlers ([exn:fail?
                     (lambda (_failure)
                       (eprintf "COMMERCE_ROLE must be all, edge, or issuer\n")
                       (exit 1))])
      (parse-service-role (env "COMMERCE_ROLE" "all"))))
  (define edge? (service-role-edge? role))
  (define issuer? (service-role-issuer? role))
  (define db-path (env-require "COMMERCE_DB_PATH"))
  (define port (and edge? (env-number "COMMERCE_PORT" 8080)))
  (define listen-ip
    (and edge? (env "COMMERCE_LISTEN_IP" "127.0.0.1")))
  (define poll-seconds
    (and issuer? (env-number "COMMERCE_POLL_SECONDS" 2)))
  ;; Never even read issuer signing secret paths in an edge-only process.
  (define issuer-name (and issuer? (env-require "COMMERCE_ISSUER")))
  (define key-id (and issuer? (env-require "PERMIT_KEY_ID")))
  (define private-key-path
    (and issuer? (env-require "PERMIT_PRIVATE_KEY_PATH")))
  (define trust-store-path
    (and issuer? (env-require "PERMIT_TRUST_STORE_PATH")))
  ;; Issuer-side evidence re-verification keys (ADR-0020): public provider
  ;; keys only, never merchant credentials. Optional per provider; a provider
  ;; without a configured verification key fails closed at issuance.
  (define alipay-verification-key-path
    (and issuer? (env "ALIPAY_PUBLIC_KEY_PATH" #f)))
  (define merchant-id (and edge? (env-require "PANCAKE_MERCHANT_ID")))
  (define merchant-key-path
    (and edge? (env-require "PANCAKE_MERCHANT_KEY_PATH")))
  (define webhook-test-key-path
    (and edge? (env-require "PANCAKE_WEBHOOK_TEST_KEY_PATH")))
  (define webhook-production-key-path
    (and edge? (env-require "PANCAKE_WEBHOOK_PRODUCTION_KEY_PATH")))
  (define environment
    (match (env "COMMERCE_ENVIRONMENT" "test")
      ["test" 'test]
      ["production" 'production]
      [other
       (eprintf "COMMERCE_ENVIRONMENT must be test or production, got ~a\n"
                other)
       (exit 1)]))

  ;; Reject production's combined web + signing process before loading any
  ;; private key or opening the store. Two OS identities remain required.
  (validate-service-role-environment! role environment)
  ;; This example deliberately bundles a Taskly demo Offer. Until a real
  ;; product replaces this entire example catalog with reviewed policy,
  ;; production issuance must fail before reading any signing keys.
  (reject-demo-catalog-in-production! role environment)

  ;; ---- trust and configuration ---------------------------------------

  (define private-key
    (and issuer? (read-ed25519-private-key private-key-path)))
  ;; The issuer's trust store is security-sensitive: Permit rejects duplicate
  ;; JSON members, malformed scalars and trailing bytes before parsing keys.
  (define trust-store
    (and issuer? (read-trust-store trust-store-path)))

  ;; PLACEHOLDER catalog: replace with the product's reviewed,
  ;; version-pinned policies. Policy ids are immutable; a rights change
  ;; is a new policy id (docs/permit-integration.md).
  (define (make-placeholder-catalog)
    (make-permit-policy-catalog
     (list (offer "taskly-pro-lifetime" "taskly" 'one-time
                  (money "USD" 2900) "taskly-pro-v1"))
     (list
      (make-permit-entitlement-policy
       "taskly-pro-v1" 1
       #:subject-type 'person
       #:grants
       (list (make-permit-grant-policy
              #:products '("taskly") #:edition "pro"))))))

  (define catalog (and issuer? (make-placeholder-catalog)))

  ;; The issuer re-verifies journaled payment evidence before any signing:
  ;; provider public keys plus the pinned catalog price anchor (issue #10).
  (define evidence-verifier
    (and issuer?
         (make-issuance-evidence-verifier
          #:catalog catalog
          #:alipay-public-key-pem
          (and alipay-verification-key-path
               (string-trim (file->string alipay-verification-key-path))))))

  ;; ---- storage, worker, edge ------------------------------------------

  (define storage (open-sqlite-commerce-storage db-path))

  (define worker
    (and issuer?
         (make-issuance-worker
          #:catalog catalog
          #:issuer issuer-name
          #:private-key private-key
          #:key-id key-id
          #:trust-store trust-store
          #:owner (env "COMMERCE_WORKER_OWNER" "commerce-service")
          #:evidence-verifier evidence-verifier)))

  (define merchant-client
    (and edge?
         (make-pancake-merchant-client
          merchant-id
          (file->string merchant-key-path)
          #:environment environment)))

  (define endpoint
    (and edge?
         (make-webhook-endpoint
          #:keyring
          (pancake-webhook-keyring
           (string-trim (file->string webhook-test-key-path))
           (string-trim (file->string webhook-production-key-path)))
          #:environment environment
          #:merchant-client merchant-client
          #:binding-lookup
          (lambda (order-id)
            (storage-checkout-binding-ref storage order-id))
          #:storage storage)))

  ;; ---- worker loop: project everything, then issue one, repeat -------

  (define stop (make-semaphore))

  (define worker-thread
    (and issuer?
         (thread
          (lambda ()
            (let loop ()
              (define fired (sync/timeout poll-seconds stop))
              (unless fired
                (with-handlers
                    ([exn:fail:commerce?
                      (lambda (_failure) (void))]
                     [exn:fail?
                      (lambda (_failure) (void))])
                  (let project ()
                    (when (storage-project-next! storage
                                                 #:processed-at
                                                 (current-seconds))
                      (project)))
                  (process-issuance-work! worker storage))
                (loop)))))))

  ;; ---- serve ----------------------------------------------------------

  (define http-stop
    (and edge?
         (serve-webhook-endpoint endpoint
                                 #:port port
                                 #:listen-ip listen-ip)))

  (printf "commerce service: role=~a db=~a environment=~a\n"
          role db-path environment)
  (flush-output)

  ;; Block forever. SIGTERM/SIGKILL ends the process; the durable design
  ;; recovers on restart. For a clean in-process shutdown, post `stop`.
  (sync stop)
  (when http-stop (http-stop))
  (when worker-thread (kill-thread worker-thread))
  (storage-close storage)
  (displayln "commerce service: stopped"))
