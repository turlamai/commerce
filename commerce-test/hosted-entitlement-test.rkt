#lang racket/base

(require rackunit
         commerce
         commerce/journal
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         commerce/hosted-entitlement
         db
         file/sha1
         racket/file)

(define (with-storage proc)
  (define dir (make-temporary-file "commerce-hosted-read-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage (open-sqlite-commerce-storage (build-path dir "db.sqlite")))
     (dynamic-wind void (lambda () (proc storage))
                   (lambda () (storage-close storage))))
   (lambda () (delete-directory/files dir))))

(test-case "untrusted subject and Offer are denied before lookup"
  (with-storage
   (lambda (storage)
     (define seen #f)
     (define (authorize issuer subject-type subject-id offer-id)
       (set! seen (list issuer subject-type subject-id offer-id))
       (and (equal? issuer "commerce.example")
            (equal? subject-type "account")
            (equal? subject-id "customer-a")
            (equal? offer-id "taskly-pro-lifetime")))
     (define (read subject-id offer-id authorization)
       (current-entitlement-snapshot
        storage #:issuer "commerce.example" #:subject-type "account"
        #:subject-id subject-id #:offer-id offer-id
        #:authorize authorization))
     (check-exn exn:fail?
                (lambda () (read "customer-a" "taskly-pro-lifetime"
                                 (lambda args #f))))
     (check-exn exn:fail?
                (lambda () (read "customer-a" "taskly-pro-lifetime"
                                 (lambda args 'yes))))
     (check-exn exn:fail?
                (lambda () (read "customer-b" "taskly-pro-lifetime"
                                 authorize)))
     (check-equal? seen
                   (list "commerce.example" "account" "customer-b"
                         "taskly-pro-lifetime"))
     (check-exn exn:fail?
                (lambda () (read "customer-a" "other-offer" authorize)))
     (check-equal? (read "customer-a" "taskly-pro-lifetime" authorize)
                   (hasheq 'status "absent")))))

(test-case "missing lineage with pinned revision or identity fails closed"
  (with-storage
   (lambda (storage)
     (define (read minimum expected-id)
       (current-entitlement-snapshot
        storage #:issuer "commerce.example"
        #:subject-type "account" #:subject-id "customer-a"
        #:offer-id "taskly-pro-lifetime"
        #:authorize (lambda (_issuer _type _subject _offer) #t)
        #:minimum-revision minimum
        #:expected-entitlement-id expected-id))
     (check-equal? (read #f #f) (hasheq 'status "absent"))
     (check-equal? (read 0 #f) (hasheq 'status "stale-revision"))
     (check-equal? (read 7 #f) (hasheq 'status "stale-revision"))
     (check-equal? (read #f "entitlement-a")
                   (hasheq 'status "lineage-mismatch"))
     (check-exn exn:fail:contract? (lambda () (read -1 #f)))
     (check-exn exn:fail:contract? (lambda () (read "3" #f)))
     (check-exn exn:fail:contract? (lambda () (read #f ""))))))

(test-case "grant to refund withdrawal and revision/lineage fences"
  (define dir (make-temporary-file "commerce-hosted-revisions-~a" 'directory))
  (define path (build-path dir "commerce.sqlite"))
  (define paid-raw #"authenticated-paid")
  (define refund-raw #"authenticated-refunded")
  (define (event raw event-id kind at)
    (make-verified-payment-event
     "mock" event-id (bytes->hex-string (sha256-bytes raw))
     kind "order-a" "taskly-pro-lifetime" "customer-a"
     (money "USD" 2900) at))
  (define (snapshot minimum expected-id)
    (define read-storage (open-sqlite-commerce-storage path))
    (dynamic-wind
     void
     (lambda ()
       (current-entitlement-snapshot
        read-storage #:issuer "commerce.example"
        #:subject-type "account" #:subject-id "customer-a"
        #:offer-id "taskly-pro-lifetime"
        #:authorize (lambda (_issuer _type _subject _offer) #t)
        #:minimum-revision minimum
        #:expected-entitlement-id expected-id))
     (lambda () (storage-close read-storage))))
  (define (insert-revision! revision action outbox-id)
    (define conn (sqlite3-connect #:database path #:mode 'read/write))
    (define payload
      (if (= revision 0) #"{\"revision\":0}" #"{\"revision\":1}"))
    (dynamic-wind
     void
     (lambda ()
       (query-exec conn "PRAGMA foreign_keys = ON")
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
  (dynamic-wind
   void
   (lambda ()
     (let ([storage (open-sqlite-commerce-storage path)])
       (dynamic-wind
        void
        (lambda ()
          (journal-accept! storage paid-raw
                           (event paid-raw "event-paid" 'payment-succeeded 100)
                           #:received-at 110)
          (storage-project-next! storage #:processed-at 111)
          (journal-accept! storage refund-raw
                           (event refund-raw "event-refund" 'payment-refunded 120)
                           #:received-at 121)
          (storage-project-next! storage #:processed-at 122))
        (lambda () (storage-close storage))))
     (let ([conn (sqlite3-connect #:database path #:mode 'read/write)])
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
        (lambda () (disconnect conn))))
     (insert-revision! 0 "grant" 1)
     (check-equal? (hash-ref (snapshot #f #f) 'status) "recorded-grant")
     (check-equal? (hash-ref (snapshot 0 "entitlement-a") 'revision) 0)
     (check-equal? (snapshot 1 "entitlement-a")
                   (hasheq 'status "stale-revision"))
     (check-equal? (snapshot #f "entitlement-other")
                   (hasheq 'status "lineage-mismatch"))
     (insert-revision! 1 "withdraw" 2)
     (let ([withdrawn (snapshot 1 "entitlement-a")])
       (check-equal? (hash-ref withdrawn 'status) "recorded-withdrawal")
       (check-equal? (hash-ref withdrawn 'revision) 1)
       (check-equal? (hash-ref withdrawn 'recorded_at) 124))
     (check-equal? (snapshot 2 "entitlement-a")
                   (hasheq 'status "stale-revision")))
   (lambda () (delete-directory/files dir))))
