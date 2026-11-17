#lang racket/base
(require commerce commerce/permit commerce/issuer commerce/provider commerce/journal
         commerce/storage commerce/storage/sqlite commerce/hosted-proof
         permit/issuer rackunit racket/file json file/sha1 db)

(define catalog
  (make-permit-policy-catalog
   (list (offer "hosted-monthly" "publy" 'one-time (money "CNY" 2900) "monthly-v1"))
   (list (make-permit-entitlement-policy "monthly-v1" 1 #:subject-type 'account
          #:grants (list (make-permit-grant-policy #:products '("publy") #:edition "personal"))
          #:constraints (make-permit-constraints-policy #:use-duration-months 1)))))
(define-values (private public) (generate-ed25519-keypair))
(define trust (jsexpr->trust-store
  (hasheq 'protocol "permit-trust-store" 'version 1 'issuer "test-issuer"
    'keys (hasheq 'test (hasheq 'algorithm "Ed25519" 'public_key (public-key->base64 public)
      'status "active" 'purposes '("entitlement") 'not_before 'null 'not_after 'null)))))
(define (with-db proc)
  (define dir (make-temporary-file "commerce-repurchase-~a" 'directory))
  (dynamic-wind void (lambda () (proc (build-path dir "db.sqlite")))
    (lambda () (delete-directory/files dir))))
(define (accept! db id order kind at #:project? [project? #t])
  (define raw (string->bytes/utf-8 id))
  (journal-accept! db raw
    (make-verified-payment-event "mock" id (bytes->hex-string (sha256-bytes raw))
      kind order "hosted-monthly" "account-a" (money "CNY" 2900) at) #:received-at at)
  (when project? (storage-project-next! db #:processed-at at)))
(define (work! db [at 1775044800])
  (process-issuance-work! (make-issuance-worker #:catalog catalog #:issuer "test-issuer"
    #:private-key private #:key-id "test" #:trust-store trust
    #:clock (lambda () (values at "2026-04-01T12:00:00Z"))) db))
(define (assert-expiry result expected)
  (check-eq? (issuance-result-disposition result) 'completed)
  (when (issuance-result-completion result)
    (define p (bytes->jsexpr (entitlement-revision-payload-bytes
      (issuance-completion-revision (issuance-result-completion result)))))
    (check-equal? (hash-ref (hash-ref p 'constraints) 'use_expires_at) expected)))
(define (proof db #:at [at "2026-04-01T12:00:00Z"])
  (current-verified-entitlement-proof db #:issuer "test-issuer" #:subject-type "account"
    #:subject-id "account-a" #:offer-id "hosted-monthly" #:product-id "publy"
    #:authorize (lambda args #t) #:trust-store trust #:at at))

(test-case "repurchase keeps one lineage; old refund preserves newer paid month across restart"
  (with-db (lambda (path)
    (define db (open-sqlite-commerce-storage path))
    (accept! db "jan-paid" "jan" 'payment-succeeded 1769853637)
    (define first (work! db))
    (assert-expiry first "2026-02-28T10:00:37Z")
    (accept! db "mar-paid" "mar" 'payment-succeeded 1774951237)
    (define second (work! db))
    (assert-expiry second "2026-04-30T10:00:37Z")
    (check-equal? (issuance-result-entitlement-id first) (issuance-result-entitlement-id second))
    (check-equal? (issuance-result-revision second) 1)
    (accept! db "jan-refund" "jan" 'payment-refunded 1775044700)
    (check-equal? (hash-ref (proof db) 'status) "refund-pending")
    (assert-expiry (work! db) "2026-04-30T10:00:37Z")
    (check-equal? (hash-ref (proof db) 'status) "verified-proof")
    (storage-close db)
    (set! db (open-sqlite-commerce-storage path))
    (check-equal? (hash-ref (proof db) 'status) "verified-proof")
    (accept! db "jan-paid-replay-new-id" "jan" 'payment-succeeded 1769853637)
    (check-false (work! db))
    (check-equal? (hash-ref (proof db) 'revision) 2)
    (accept! db "jan-refund-new-delivery" "jan" 'payment-refunded 1775044700)
    (check-false (work! db))
    (check-equal? (hash-ref (proof db) 'status) "verified-proof")
    (accept! db "mar-refund" "mar" 'payment-refunded 1775044750)
    (define withdrawn (work! db))
    (check-eq? (issuance-result-disposition withdrawn) 'completed)
    (check-equal? (hash-ref (proof db) 'status) "recorded-withdrawal")
    (storage-close db))))

(test-case "refund newest order restores older unrefunded expiry, not all rights"
  (with-db (lambda (path)
    (define db (open-sqlite-commerce-storage path))
    (accept! db "a-paid" "a" 'payment-succeeded 1774951237)
    (work! db)
    (accept! db "b-paid" "b" 'payment-succeeded 1775001600)
    (work! db)
    (accept! db "b-refund" "b" 'payment-refunded 1775044700)
    (assert-expiry (work! db) "2026-04-30T10:00:37Z")
    (check-equal? (hash-ref (proof db) 'status) "verified-proof")
    (storage-close db))))

(test-case "backlogged paid/refund facts cannot transiently resurrect or shrink rights"
  (with-db (lambda (path)
    (define db (open-sqlite-commerce-storage path))
    (accept! db "new-paid" "new" 'payment-succeeded 1774951237)
    (accept! db "old-paid" "old" 'payment-succeeded 1769853637)
    (accept! db "old-refund" "old" 'payment-refunded 1775044700)
    (for ([i (in-range 3)]) (assert-expiry (work! db) "2026-04-30T10:00:37Z"))
    (check-equal? (hash-ref (proof db) 'status) "verified-proof")
    (check-false (work! db))
    (storage-close db))))

(test-case "refund before payment stays removed and does not permanently block next purchase"
  (with-db (lambda (path)
    (define db (open-sqlite-commerce-storage path))
    (accept! db "old-refund-first" "old" 'payment-refunded 1775044700)
    (accept! db "old-paid-late" "old" 'payment-succeeded 1769853637)
    (accept! db "next-paid" "next" 'payment-succeeded 1774951237)
    (assert-expiry (work! db) "2026-04-30T10:00:37Z")
    (check-equal? (hash-ref (proof db) 'status) "verified-proof")
    (storage-close db))))

(test-case "new scoped evidence during signing refuses stale publication"
  (with-db (lambda (path)
    (define db (open-sqlite-commerce-storage path))
    (accept! db "race-paid" "race" 'payment-succeeded 1774951237)
    (define calls 0)
    (define result
      (process-issuance-work!
       (make-issuance-worker #:catalog catalog #:issuer "test-issuer"
        #:private-key private #:key-id "test" #:trust-store trust
        #:clock (lambda ()
          (set! calls (add1 calls))
          (when (= calls 2)
            (accept! db "race-refund" "race" 'payment-refunded 1775044700 #:project? #f))
          (values 1775044800 "2026-04-01T12:00:00Z"))) db))
    (check-eq? (issuance-result-disposition result) 'released)
    (check-eq? (issuance-result-error-code result) 'prepaid-snapshot-stale)
    (check-false (storage-lineage-ref db #:issuer "test-issuer" #:subject-type "account"
                  #:subject-id "account-a" #:offer-id "hosted-monthly"))
    (storage-redrive-issuance-work! db "mock/race/grant" #:now 1775044801)
    (check-eq? (issuance-result-disposition (work! db 1775044801)) 'completed)
    (check-equal? (hash-ref (proof db #:at "2026-04-01T12:00:02Z") 'status) "not-usable")
    (storage-close db))))

(test-case "prepaid checkpoint is append-only and v8 migration preserves journal bytes"
  (with-db (lambda (path)
    (define store (open-sqlite-commerce-storage path))
    (accept! store "migration-paid" "migration" 'payment-succeeded 1774951237)
    (work! store)
    (storage-close store)
    (define sql (sqlite3-connect #:database path #:mode 'read/write))
    (check-equal? (query-value sql "SELECT COUNT(*) FROM commerce_prepaid_checkpoint") 1)
    (check-exn exn:fail? (lambda () (query-exec sql "DELETE FROM commerce_prepaid_checkpoint")))
    (check-exn exn:fail? (lambda () (query-exec sql "UPDATE commerce_prepaid_checkpoint SET journal_sequence=0")))
    (define original (query-value sql "SELECT raw_payload FROM commerce_event_journal LIMIT 1"))
    (query-exec sql "DROP TABLE commerce_prepaid_checkpoint")
    (query-exec sql "PRAGMA user_version = 8")
    (disconnect sql)
    (check-exn exn:fail:commerce? (lambda () (open-sqlite-commerce-storage path #:read-only? #t)))
    (set! store (open-sqlite-commerce-storage path))
    (storage-close store)
    (set! sql (sqlite3-connect #:database path #:mode 'read-only))
    (check-equal? (query-value sql "PRAGMA user_version") 9)
    (check-equal? (query-value sql "SELECT raw_payload FROM commerce_event_journal LIMIT 1") original)
    (check-equal? (query-value sql "SELECT COUNT(*) FROM commerce_prepaid_checkpoint") 0)
    (disconnect sql))))
