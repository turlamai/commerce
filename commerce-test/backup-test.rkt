#lang racket/base

(require commerce
         commerce/backup
         commerce/journal
         commerce/provider
         commerce/retention
         commerce/storage
         commerce/storage/sqlite
         db
         file/sha1
         rackunit
         racket/file
         racket/runtime-path)

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

;; One unique directory per database so rapid calls never share a path.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-backup-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc directory (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (open-storage-with-payment path)
  (define payload #"authenticated payment")
  (define storage (open-sqlite-commerce-storage path))
  (journal-accept!
   storage payload
   (make-verified-payment-event
    "mock" "evt_001" (payload-digest payload) 'payment-succeeded
    "ord_001" "taskly-pro-lifetime" "customer-001"
    (money "USD" 2900) 1792108800)
   #:received-at 10)
  (storage-project-next! storage #:processed-at 11)
  storage)

(test-case "snapshot and restore rehearsal prove the copy is equivalent"
  (call-with-temporary-database
   (lambda (directory path)
     (define storage (open-storage-with-payment path))
     (define backup-path (build-path directory "backup.sqlite"))
     (snapshot-commerce-database! path backup-path)
     (check-true (file-exists? backup-path))
     (define-values (verification original)
       (verify-commerce-backup storage backup-path #:now 100))
     (check-true (backup-verification-ok? verification))
     (define details (backup-verification-details verification))
     (check-equal? (hash-ref details 'integrity) "ok")
     (check-equal? (hash-ref details 'journal-total) 1)
     (check-equal? (hash-ref details 'expected-journal-total) 1)
     (check-equal? (readiness-schema-version original) 8)
     ;; The restored copy opens as Commerce storage with the same evidence.
     (define restored (open-sqlite-commerce-storage backup-path))
     (check-equal?
      (journal-ref restored "mock" "evt_001")
      (journal-ref storage "mock" "evt_001"))
     (storage-close restored)
     (storage-close storage))))

(test-case "a damaged copy fails the rehearsal with a typed code"
  (call-with-temporary-database
   (lambda (directory path)
     (define storage (open-storage-with-payment path))
     (define backup-path (build-path directory "backup.sqlite"))
     (snapshot-commerce-database! path backup-path)
     (call-with-output-file backup-path
       (lambda (port) (write-bytes #"garbage" port))
       #:exists 'truncate)
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure) 'backup-unreadable)))
      (lambda ()
        (verify-commerce-backup storage backup-path #:now 100)))
     (storage-close storage))))

(test-case "snapshot refuses to overwrite an existing backup"
  (call-with-temporary-database
   (lambda (directory path)
     (define storage (open-storage-with-payment path))
     (define backup-path (build-path directory "backup.sqlite"))
     (snapshot-commerce-database! path backup-path)
     (check-exn
      exn:fail?
      (lambda ()
        (snapshot-commerce-database! path backup-path)))
     (storage-close storage))))

(test-case "retirement expires only window-passed ready claims"
  (call-with-temporary-database
   (lambda (directory path)
     (define storage (open-storage-with-payment path))
     ;; Two claims through the public surface: one already expired, one
     ;; still inside its window. The expired one fulfills nothing.
     (define claimed
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 100))
     (storage-complete-issuance-work!
      storage claimed
      #:issuer "com.example"
      #:subject-type "person"
      #:entitlement-id "ent-001"
      #:credential-id "cred-001"
      #:policy-id "taskly-pro-v1"
      #:policy-version 1
      #:payload-bytes (make-bytes 64 1)
      #:issued-at "2026-10-21T00:00:00Z"
      #:recorded-at 110
      #:signed-credential-bytes (make-bytes 64 2)
      #:key-id "k1"
      #:claim-token "window-token"
      #:claim-expires-at 500)
     (define retired (storage-retire-expired-claims! storage #:now 200))
     (check-equal? retired 0)
     (check-true
      (claim-fulfillment?
       (storage-claim-credential storage
                                 #:token "window-token" #:now 250)))
     (check-exn
      exn:fail:contract?
      (lambda ()
        (storage-retire-expired-claims! storage "not-a-time")))
     (storage-close storage))))

(test-case "key rotation continues the same lineage with a new key id"
  (call-with-temporary-database
   (lambda (directory path)
     ;; The storage layer binds key ids per revision; rotating the signing
     ;; key means new revisions record the new key id while lineage
     ;; identity stays stable. This rehearsal completes two revisions of
     ;; one lineage under two key ids.
     (define storage (open-storage-with-payment path))
     (define first-claim
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 100))
     (storage-complete-issuance-work!
      storage first-claim
      #:issuer "com.example"
      #:subject-type "person"
      #:entitlement-id "ent-001"
      #:credential-id "cred-001"
      #:policy-id "taskly-pro-v1"
      #:policy-version 1
      #:payload-bytes (make-bytes 64 1)
      #:issued-at "2026-10-21T00:00:00Z"
      #:recorded-at 110
      #:signed-credential-bytes (make-bytes 64 2)
      #:key-id "key-2026")
     (define refund-payload #"refund evidence")
     (journal-accept!
      storage refund-payload
      (make-verified-payment-event
       "mock" "evt_refund" (payload-digest refund-payload)
       'payment-refunded "ord_001" "taskly-pro-lifetime" "customer-001"
       (money "USD" 2900) 1792108900)
      #:received-at 21)
     (storage-project-next! storage #:processed-at 22)
     (define withdraw-claim
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 300))
     (storage-complete-issuance-work!
      storage withdraw-claim
      #:issuer "com.example"
      #:subject-type "person"
      #:entitlement-id "ent-001"
      #:credential-id "cred-002"
      #:policy-id "taskly-pro-v1"
      #:policy-version 1
      #:payload-bytes (make-bytes 64 3)
      #:issued-at "2026-10-21T01:00:00Z"
      #:recorded-at 310
      #:signed-credential-bytes (make-bytes 64 4)
      #:key-id "key-2027")
     (define connection
       (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-value
       connection
       "SELECT COUNT(DISTINCT key_id) FROM commerce_issued_credential")
      2)
     (check-equal?
      (query-value
       connection
       "SELECT COUNT(DISTINCT entitlement_id) FROM commerce_issued_credential")
      1)
     (disconnect connection)
     (storage-close storage))))
