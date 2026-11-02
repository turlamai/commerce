#lang racket/base

(require commerce
         commerce/health
         commerce/log
         commerce/issuer
         commerce/journal
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         db
         file/sha1
         racket/match
         permit/issuer
         rackunit
         racket/file
         racket/port)

(define usd-29 (money "USD" 2900))

(define taskly-offer
  (offer "taskly-pro-lifetime" "taskly" 'one-time usd-29 "taskly-pro-v1"))

(define taskly-policy
  (make-permit-entitlement-policy
   "taskly-pro-v1" 1
   #:subject-type 'person
   #:grants (list (make-permit-grant-policy #:products '("taskly")))))

(define catalog
  (make-permit-policy-catalog (list taskly-offer) (list taskly-policy)))

(define issuer-name "com.turinglambdaai")
(define key-id "test-2026")

(define-values (private-key public-key) (generate-ed25519-keypair))

(define trust-store
  (jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1
           'issuer issuer-name
           'keys
           (hasheq 'test-2026
                   (hasheq 'algorithm "Ed25519"
                           'public_key (public-key->base64 public-key)
                           'status "active"
                           'purposes '("entitlement")
                           'not_before 'null
                           'not_after 'null)))))

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

;; One unique directory per database so rapid calls never share a path.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-health-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (open-paid-storage path)
  (define payload #"authenticated payment")
  (define storage (open-sqlite-commerce-storage path))
  (journal-accept!
   storage payload
   (make-verified-payment-event
    "mock" "evt_001" (payload-digest payload) 'payment-succeeded
    "ord_001" "taskly-pro-lifetime" "customer-001" usd-29 1792108800)
   #:received-at 10)
  (storage-project-next! storage #:processed-at 11)
  storage)

(test-case "an empty store reports a clean readiness snapshot"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-sqlite-commerce-storage path))
     (define snapshot (storage-readiness storage #:now 100))
     (check-equal? (readiness-schema-version snapshot) 8)
     (check-equal? (readiness-journal-total snapshot) 0)
     (check-equal? (readiness-journal-unprojected snapshot) 0)
     (check-equal? (readiness-projection-blocked snapshot) 0)
     (check-equal? (readiness-work-pending snapshot) 0)
     (check-equal? (readiness-work-processing snapshot) 0)
     (check-equal? (readiness-work-stale-lease snapshot) 0)
     (check-false (readiness-work-oldest-pending-at snapshot))
     (define report (health-report storage #:now 100))
     (check-equal? (health-status-warnings report) '())
     (storage-close storage))))

(test-case "pending, stale, and blocked work are visible and classified"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define pending
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 100))
     ;; A claim nobody fulfills inside its window.
     (storage-complete-issuance-work!
      storage pending
      #:issuer issuer-name
      #:subject-type "person"
      #:entitlement-id "ent-001"
      #:credential-id "cred-001"
      #:policy-id "taskly-pro-v1"
      #:policy-version 1
      #:payload-bytes (make-bytes 64 1)
      #:issued-at "2026-10-21T00:00:00Z"
      #:recorded-at 110
      #:signed-credential-bytes (make-bytes 64 2)
      #:key-id key-id
      #:claim-token "window-token"
      #:claim-expires-at 500)
     ;; A second order whose projection is durably blocked.
     (define conflict-payload #"conflicting payment")
     (journal-accept!
      storage conflict-payload
      (make-verified-payment-event
       "mock" "evt_002" (payload-digest conflict-payload)
       'payment-succeeded "ord_001" "taskly-pro-lifetime" "customer-002"
       usd-29 1792108900)
      #:received-at 21)
     (storage-project-next! storage #:processed-at 22)
     ;; A third order left pending forever.
     (define stale-payload #"stale payment")
     (journal-accept!
      storage stale-payload
      (make-verified-payment-event
       "mock" "evt_003" (payload-digest stale-payload)
       'payment-succeeded "ord_003" "taskly-pro-lifetime" "customer-003"
       usd-29 1792108950)
      #:received-at 51)
     (storage-project-next! storage #:processed-at 52)
     (define snapshot (storage-readiness storage #:now 600))
     (check-equal? (readiness-journal-total snapshot) 3)
     (check-equal? (readiness-projection-blocked snapshot) 1)
     (check-equal? (readiness-work-pending snapshot) 1)
     (check-equal? (readiness-work-processing snapshot) 0)
     (check-equal? (readiness-claim-ready snapshot) 1)
     (check-equal? (readiness-claim-claimed snapshot) 0)
     (check-equal? (readiness-claim-window-passed snapshot) 1)
     (define codes
       (map health-warning-code (health-status-warnings
                                 (health-report storage #:now 600))))
     (check-not-false (memq 'projection-blocked codes))
     (check-not-false (memq 'claim-window-passed codes))
     (storage-close storage))))

(test-case "an expired processing lease is reported as stale"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (storage-claim-issuance-work! storage
                                   #:owner "worker-a"
                                   #:lease-seconds 30
                                   #:now 100)
     (check-equal? (readiness-work-stale-lease
                    (storage-readiness storage #:now 129))
                   0)
     (check-equal? (readiness-work-stale-lease
                    (storage-readiness storage #:now 130))
                   1)
     (define warnings
       (health-status-warnings (health-report storage #:now 130)))
     (check-equal?
      (map health-warning-code warnings)
      (list 'issuance-lease-expired))
     ;; The operator log carries the same evidence.
     (define receiver (make-log-receiver commerce-logger 'warning))
     (health-report! storage #:now 130)
     (match-define (vector _level _message data _topic)
       (sync/timeout 10 receiver))
     (check-eq? (commerce-log-event-code data) 'issuance-lease-expired)
     (check-equal? (hash-ref (commerce-log-event-fields data) 'count) 1)
     (storage-close storage))))
