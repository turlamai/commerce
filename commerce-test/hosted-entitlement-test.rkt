#lang racket/base
(require rackunit
         commerce
         commerce/journal
         commerce/provider
         db
         file/sha1
         commerce/storage
         commerce/storage/sqlite
         commerce/hosted-entitlement
         racket/file)

(define (with-storage proc)
  (define dir (make-temporary-file "commerce-hosted-read-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define store (open-sqlite-commerce-storage (build-path dir "db.sqlite")))
     (dynamic-wind void (lambda () (proc store))
                   (lambda () (storage-close store))))
   (lambda () (delete-directory/files dir))))

(test-case "scoped reads default to no access, no existence leak"
  (with-storage
   (lambda (storage)
     (define (read authorize)
       (current-entitlement-snapshot
        storage #:issuer "commerce.example"
        #:subject-type "account" #:subject-id "customer-a"
        #:offer-id "taskly-pro-lifetime" #:authorize authorize))
     (check-exn exn:fail? (lambda () (read (lambda args #f))))
     (check-exn exn:fail? (lambda () (read (lambda args 'yes))))
     (check-equal? (read (lambda (issuer type subject offer)
                           (and (equal? issuer "commerce.example")
                                (equal? type "account")
                                (equal? subject "customer-a")
                                (equal? offer "taskly-pro-lifetime"))))
                   (hasheq 'status "absent")))))


(test-case "authorization sees all four scope fields and denies cross-account reads"
  (with-storage
   (lambda (storage)
     (define seen #f)
     (define (authorize issuer subject-type subject-id offer-id)
       (set! seen (list issuer subject-type subject-id offer-id))
       (and (equal? issuer "commerce.example")
            (equal? subject-type "account")
            (equal? subject-id "customer-a")
            (equal? offer-id "taskly-pro-lifetime")))
     (define (lookup subject-id offer-id)
       (current-entitlement-snapshot
        storage #:issuer "commerce.example" #:subject-type "account"
        #:subject-id subject-id #:offer-id offer-id
        #:authorize authorize))
     (check-exn exn:fail? (lambda () (lookup "customer-b" "taskly-pro-lifetime")))
     (check-equal? seen
                   (list "commerce.example" "account" "customer-b"
                         "taskly-pro-lifetime"))
     (check-exn exn:fail? (lambda () (lookup "customer-a" "other-offer")))
     (check-equal? (lookup "customer-a" "taskly-pro-lifetime")
                   (hasheq 'status "absent")))))

(test-case "minimum revision is fail-closed for missing ledger state"
  (with-storage
   (lambda (storage)
     (define (read minimum)
       (current-entitlement-snapshot
        storage #:issuer "commerce.example"
        #:subject-type "account" #:subject-id "customer-a"
        #:offer-id "taskly-pro-lifetime"
        #:authorize (lambda (_issuer _type _subject _offer) #t)
        #:minimum-revision minimum))
     (check-equal? (read #f) (hasheq 'status "absent"))
     (check-equal? (read 0) (hasheq 'status "stale-revision"))
     (check-equal? (read 7) (hasheq 'status "stale-revision"))
     (check-exn exn:fail:contract? (lambda () (read -1)))
     (check-exn exn:fail:contract? (lambda () (read "3"))))))

(test-case "latest ledger revision and refund withdrawal override older grant"
  (define dir (make-temporary-file "commerce-hosted-revisions-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define path (build-path dir "commerce.sqlite"))
     (define storage (open-sqlite-commerce-storage path))
     (define paid-raw #"authenticated-paid")
     (define refund-raw #"authenticated-refunded")
     (define (event raw event-id kind at)
       (make-verified-payment-event
        "mock" event-id (bytes->hex-string (sha256-bytes raw))
        kind "order-a" "taskly-pro-lifetime" "customer-a"
        (money "USD" 2900) at))
     (journal-accept! storage paid-raw
                      (event paid-raw "event-paid" 'payment-succeeded 100)
                      #:received-at 110)
     (storage-project-next! storage #:processed-at 111)
     (journal-accept! storage refund-raw
                      (event refund-raw "event-refund" 'payment-refunded 120)
                      #:received-at 121)
     (storage-project-next! storage #:processed-at 122)
     (storage-close storage)

     (define (snapshot minimum)
       (define read-storage (open-sqlite-commerce-storage path))
       (dynamic-wind
        void
        (lambda ()
          (current-entitlement-snapshot
           read-storage #:issuer "commerce.example"
           #:subject-type "account" #:subject-id "customer-a"
           #:offer-id "taskly-pro-lifetime"
           #:authorize (lambda (_issuer _type _subject _offer) #t)
           #:minimum-revision minimum))
        (lambda () (storage-close read-storage))))
     (define (insert-revision! revision action outbox-id)
       (define conn (sqlite3-connect #:database path #:mode 'read/write))
       (dynamic-wind
        void
        (lambda ()
          (query-exec conn "PRAGMA foreign_keys = ON")
          (define payload
            (if (= revision 0) #"{\"revision\":0}" #"{\"revision\":1}"))
          (query-exec
           conn
           "INSERT INTO commerce_entitlement_revision
             (entitlement_id, revision, previous_revision, credential_id,
              issuance_outbox_id, action, policy_id, policy_version,
              payload_bytes, payload_digest, issued_at, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)"
           "entitlement-a" revision
           (if (= revision 0) sql-null (sub1 revision))
           (if (= revision 0) "credential-grant" "credential-withdraw")
           outbox-id action "taskly-pro-v1"
           payload (bytes->hex-string (sha256-bytes payload))
           (if (= revision 0) "2026-10-17T03:00:00Z"
               "2026-10-17T03:01:00Z")
           (+ 123 revision)))
        (lambda () (disconnect conn))))
     (define conn (sqlite3-connect #:database path #:mode 'read/write))
     (dynamic-wind
      void
      (lambda ()
        (query-exec conn "PRAGMA foreign_keys = ON")
        (query-exec
         conn
         "INSERT INTO commerce_entitlement_lineage
           (entitlement_id, issuer, subject_type, subject_id,
            credential_type, offer_id, created_at)
          VALUES ('entitlement-a', 'commerce.example', 'account', 'customer-a',
                  'entitlement', 'taskly-pro-lifetime', 111)"))
      (lambda () (disconnect conn)))
     (insert-revision! 0 "grant" 1)
     (check-equal? (hash-ref (snapshot #f) 'status) "recorded-grant")
     (check-equal? (hash-ref (snapshot 0) 'revision) 0)
     (check-equal? (snapshot 1) (hasheq 'status "stale-revision"))
     (insert-revision! 1 "withdraw" 2)
     (define withdrawn (snapshot 1))
     (check-equal? (hash-ref withdrawn 'status) "recorded-withdrawal")
     (check-equal? (hash-ref withdrawn 'revision) 1)
     (check-equal? (hash-ref withdrawn 'recorded_at) 124)
     (check-equal? (snapshot 2) (hasheq 'status "stale-revision")))
   (lambda () (delete-directory/files dir))))
