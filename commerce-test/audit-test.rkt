#lang racket/base

(require commerce
         commerce/issuer
         commerce/journal
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         db
         file/sha1
         permit/issuer
         rackunit
         racket/file
         racket/port
         racket/string)

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
    (make-temporary-file "commerce-audit-~a" 'directory))
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

(define (worker clock-epoch)
  (make-issuance-worker
   #:catalog catalog
   #:issuer issuer-name
   #:private-key private-key
   #:key-id key-id
   #:trust-store trust-store
   #:clock (lambda () (values clock-epoch "2026-10-21T00:00:00Z"))))

(define (count-rows path table)
  (define connection (sqlite3-connect #:database path #:mode 'read-only))
  (begin0
    (query-value connection (format "SELECT COUNT(*) FROM ~a" table))
    (disconnect connection)))

(test-case "fresh databases create schema v7 with append-only audit"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-sqlite-commerce-storage path))
     (storage-close storage)
     (define connection (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal? (query-value connection "PRAGMA user_version") 8)
     (check-equal?
      (query-value
       connection
       "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'
        AND name = 'commerce_operator_audit'")
      1)
     (check-exn
      exn:fail:sql?
      (lambda ()
        (query-exec connection "DELETE FROM commerce_operator_audit")))
     (disconnect connection))))

(test-case "schema v6 migrates in place to v7"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (storage-close storage)
     (define connection
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec connection "DROP TABLE commerce_operator_audit")
     (query-exec connection "ALTER TABLE commerce_event_journal DROP COLUMN signature_evidence")
     (query-exec connection "PRAGMA user_version = 6")
     (disconnect connection)
     (define migrated (open-sqlite-commerce-storage path))
     (storage-close migrated)
     (define reopened (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal? (query-value reopened "PRAGMA user_version") 8)
     (check-equal?
      (query-value
       reopened
       "SELECT status FROM commerce_issuance_outbox WHERE id = 1")
      "pending")
     (disconnect reopened))))

(test-case "audit records are append-only and filterable"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define first-id
       (storage-append-audit! storage
                              #:action "refund-approved"
                              #:operator "ops-alice"
                              #:reason "customer refunded by provider"
                              #:subject "mock/ord_001"
                              #:created-at 100))
     (define second-id
       (storage-append-audit! storage
                              #:action "mapping-repair"
                              #:operator "ops-bob"
                              #:reason "corrected offer mapping"
                              #:subject "taskly-pro-lifetime"
                              #:created-at 200))
     (check-not-false first-id)
     (check-not-false second-id)
     (check-equal? (length (storage-audit-scan storage)) 2)
     (define refunds
       (storage-audit-scan storage #:action "refund-approved"))
     (check-equal? (length refunds) 1)
     (check-equal? (operator-audit-record-operator (car refunds))
                   "ops-alice")
     (check-equal? (operator-audit-record-created-at (car refunds)) 100)
     (check-exn
      exn:fail:contract?
      (lambda ()
        (storage-append-audit! storage
                               #:action "refund-approved"
                               #:operator "ops-alice"
                               #:reason ""
                               #:subject "mock/ord_001"
                               #:created-at 300)))
     (storage-close storage))))

(test-case "reissue issues a fresh claim for the same credential with audit"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define result (process-issuance-work! (worker 100) storage))
     (check-eq? (issuance-result-disposition result) 'completed)
     (define credential-id
       (issued-credential-record-credential-id
        (storage-issued-credential-ref storage 1)))
     ;; The original claim window passes without fulfillment.
     (storage-retire-expired-claims! storage #:now 2593200)
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure) 'claim-expired)))
      (lambda ()
        (storage-claim-credential storage
                                  #:token (issuance-result-claim-token
                                           result)
                                  #:now 2593300)))
     ;; The operator reissues: same credential, fresh token, audited.
     (define new-claim
       (storage-reissue-claim! storage
                               #:claim-id 1
                               #:claim-token "fresh-customer-token"
                               #:expires-at 5200000
                               #:operator "ops-carol"
                               #:reason "original claim window expired"
                               #:now 2593400))
     (check-eq? (claim-record-status new-claim) 'ready)
     (check-equal? (claim-record-issued-credential-id new-claim) 1)
     (define fulfillment
       (storage-claim-credential storage
                                 #:token "fresh-customer-token"
                                 #:now 2593500))
     (check-equal?
      (issued-credential-record-credential-id
       (claim-fulfillment-credential fulfillment))
      credential-id)
     (storage-close storage)
     ;; One credential, two claims, one audited reissue.
     (check-equal?
      (count-rows path "commerce_issued_credential")
      1)
     (check-equal? (count-rows path "commerce_claim") 2)
     (define audit-storage (open-sqlite-commerce-storage path))
     (define audits
       (storage-audit-scan audit-storage #:action "reissue-claim"))
     (check-equal? (length audits) 1)
     (check-equal? (operator-audit-record-operator (car audits))
                   "ops-carol")
     (check-true
      (string-contains? (operator-audit-record-subject (car audits))
                        "credential"))
     (storage-close audit-storage))))

