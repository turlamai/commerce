#lang racket/base

(require commerce
         commerce/issuer
         commerce/permit
         commerce/storage
         commerce/storage/sqlite
         commerce/journal
         commerce/provider
         db
         file/sha1
         json
         permit/envelope
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
   #:grants
   (list (make-permit-grant-policy #:products '("taskly")))))

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

;; A minimal valid Permit entitlement payload for storage-level tests; the
;; signer only signs schema-valid credential payloads.
(define valid-payload
  (payload->bytes
   (entitlement-payload
    #:issuer issuer-name
    #:credential-id "cred-001"
    #:entitlement-id "ent-001"
    #:subject (subject #:type "person" #:id "customer-001")
    #:grants (list (grant #:products '("taskly")))
    #:constraints (constraints)
    #:issued-at "2026-10-21T00:00:00Z")))

(define (paid-event payload)
  (make-verified-payment-event
   "mock" "evt_001" (payload-digest payload) 'payment-succeeded
   "ord_001" "taskly-pro-lifetime" "customer-001" usd-29 1792108800))

;; One unique directory per database so rapid calls never share a path.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-delivery-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

(define (open-paid-storage path)
  (define payload #"authenticated payment")
  (define storage (open-sqlite-commerce-storage path))
  (journal-accept! storage payload (paid-event payload) #:received-at 10)
  (storage-project-next! storage #:processed-at 11)
  storage)

(define (database-count path table)
  (define connection (sqlite3-connect #:database path #:mode 'read-only))
  (begin0
    (query-value connection (format "SELECT COUNT(*) FROM ~a" table))
    (disconnect connection)))

(define (envelope-bytes-for payload-bytes)
  (define envelope
    (issue-credential payload-bytes private-key key-id trust-store))
  (with-output-to-bytes
    (lambda () (write-json (envelope->jsexpr envelope)))))

(define (worker clock-epoch)
  (make-issuance-worker
   #:catalog catalog
   #:issuer issuer-name
   #:private-key private-key
   #:key-id key-id
   #:trust-store trust-store
   #:clock (lambda () (values clock-epoch (format "~a-issued" clock-epoch)))))

(test-case "fresh databases create schema v4 with delivery evidence"
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
        AND name IN ('commerce_issued_credential', 'commerce_claim')")
      2)
     (check-equal?
      (query-value
       connection
       "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'
        AND name IN ('commerce_issued_credential_no_update',
                     'commerce_issued_credential_no_delete',
                     'commerce_claim_no_delete')")
      3)
     (disconnect connection))))

(test-case "schema v3 migrates in place to v4 without touching evidence"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define work (storage-outbox-ref storage "mock/ord_001/grant"))
     (storage-close storage)
     (define connection
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec connection "PRAGMA foreign_keys = ON")
     (query-exec connection "DROP TABLE commerce_operator_audit")
     (query-exec connection "DROP TABLE commerce_claim")
     (query-exec connection "DROP TABLE commerce_issued_credential")
     (query-exec connection "DROP TABLE commerce_checkout_binding")
     (query-exec connection
                 "ALTER TABLE commerce_event_journal DROP COLUMN paid_through")
     (query-exec connection
                 "ALTER TABLE commerce_order_projection DROP COLUMN paid_through")
     (query-exec connection
                 "ALTER TABLE commerce_event_journal DROP COLUMN signature_evidence")
     (query-exec connection "PRAGMA user_version = 3")
     (check-equal?
      (query-value
       connection
       "SELECT status FROM commerce_issuance_outbox WHERE id = 1")
      "pending")
     (disconnect connection)
     (define migrated (open-sqlite-commerce-storage path))
     (storage-close migrated)
     (define reopened (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal? (query-value reopened "PRAGMA user_version") 8)
     (check-equal?
      (query-row
       reopened
       "SELECT idempotency_key, status, attempts FROM commerce_issuance_outbox")
      (vector "mock/ord_001/grant" "pending" 0))
     (disconnect reopened))))

(test-case "completion with signed bytes records the credential and claim"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment")
     (define storage (open-paid-storage path))
     (define claimed
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 100))
     (define issued-at "2026-10-21T00:00:00Z")
     (define completion
       (storage-complete-issuance-work! storage claimed
                                        #:issuer issuer-name
                                        #:subject-type "person"
                                        #:entitlement-id "ent-001"
                                        #:credential-id "cred-001"
                                        #:policy-id "taskly-pro-v1"
                                        #:policy-version 1
                                        #:payload-bytes
                                        valid-payload
                                        #:issued-at issued-at
                                        #:recorded-at 120
                                        #:signed-credential-bytes
                                        (envelope-bytes-for valid-payload)
                                        #:key-id key-id
                                        #:claim-token "claim-token-abc"
                                        #:claim-expires-at 100000))
     (check-eq? (issuance-outbox-item-status
                 (issuance-completion-outbox completion))
                'completed)
     (storage-close storage)
     (define connection (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-row
       connection
       #<<SQL
SELECT issuance_outbox_id, entitlement_id, revision, credential_id, key_id
FROM commerce_issued_credential
SQL
       )
      (vector 1 "ent-001" 0 "cred-001" key-id))
     (define claim-row
       (query-row
        connection
        #<<SQL
SELECT status, notified_at, claimed_at, expires_at FROM commerce_claim
SQL
        ))
     (check-equal? (vector-ref claim-row 0) "ready")
     (check-true (sql-null? (vector-ref claim-row 1)))
     (check-true (sql-null? (vector-ref claim-row 2)))
     (check-equal? (vector-ref claim-row 3) 100000)
     ;; Only the token digest is stored, never the token itself.
     (check-equal?
      (query-value connection "SELECT claim_token_digest FROM commerce_claim")
      (payload-digest #"claim-token-abc"))
     (disconnect connection))))

(test-case "claim fulfillment returns the exact signed envelope once"
  (call-with-temporary-database
   (lambda (path)
     (define payload-bytes valid-payload)
     (define envelope-bytes (envelope-bytes-for payload-bytes))
     (define storage (open-paid-storage path))
     (define claimed
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 100))
     (storage-complete-issuance-work! storage claimed
                                      #:issuer issuer-name
                                      #:subject-type "person"
                                      #:entitlement-id "ent-001"
                                      #:credential-id "cred-001"
                                      #:policy-id "taskly-pro-v1"
                                      #:policy-version 1
                                      #:payload-bytes payload-bytes
                                      #:issued-at "2026-10-21T00:00:00Z"
                                      #:recorded-at 120
                                      #:signed-credential-bytes envelope-bytes
                                      #:key-id key-id
                                      #:claim-token "claim-token-abc"
                                      #:claim-expires-at 100000)
     (define notified
       (storage-mark-claim-notified storage
                                    #:token "claim-token-abc"
                                    #:now 150))
     (check-true (void? notified))
     (define fulfillment
       (storage-claim-credential storage
                                 #:token "claim-token-abc"
                                 #:now 200))
     (check-equal? (claim-fulfillment-claimed-at fulfillment) 200)
     (define credential
       (claim-fulfillment-credential fulfillment))
     (check-equal? (issued-credential-record-entitlement-id credential)
                   "ent-001")
     (check-equal? (issued-credential-record-revision credential) 0)
     (check-equal? (issued-credential-record-envelope-bytes credential)
                   envelope-bytes)
     ;; The delivered bytes verify as a Permit envelope signed by the
     ;; recorded key.
     (define delivered
       (read-envelope (open-input-bytes
                       (issued-credential-record-envelope-bytes
                        credential))))
     (check-true (verify-envelope-signature delivered public-key))
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure)
                  'claim-already-claimed)))
      (lambda ()
        (storage-claim-credential storage
                                  #:token "claim-token-abc"
                                  #:now 300)))
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure) 'claim-not-found)))
      (lambda ()
        (storage-claim-credential storage
                                  #:token "no-such-token"
                                  #:now 300)))
     (storage-close storage)
     (define connection (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-row
       connection
       "SELECT status, notified_at, claimed_at FROM commerce_claim")
      (vector "claimed" 150 200))
     (check-exn
      exn:fail:sql?
      (lambda ()
        (query-exec
         connection
         "DELETE FROM commerce_claim")))
     (disconnect connection))))

(test-case "an expired claim fails closed without mutation"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define claimed
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 100))
     (storage-complete-issuance-work! storage claimed
                                      #:issuer issuer-name
                                      #:subject-type "person"
                                      #:entitlement-id "ent-001"
                                      #:credential-id "cred-001"
                                      #:policy-id "taskly-pro-v1"
                                      #:policy-version 1
                                      #:payload-bytes valid-payload
                                      #:issued-at "2026-10-21T00:00:00Z"
                                      #:recorded-at 120
                                      #:signed-credential-bytes
                                      (envelope-bytes-for valid-payload)
                                      #:key-id key-id
                                      #:claim-token "claim-token-abc"
                                      #:claim-expires-at 1000)
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure) 'claim-expired)))
      (lambda ()
        (storage-claim-credential storage
                                  #:token "claim-token-abc"
                                  #:now 1001)))
     (check-exn
      (lambda (failure)
        (and (exn:fail:commerce? failure)
             (eq? (exn:fail:commerce-code failure) 'claim-not-found)))
      (lambda ()
        (storage-mark-claim-notified storage
                                     #:token "missing"
                                     #:now 100)))
     (storage-close storage)
     (define connection (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-value connection "SELECT status FROM commerce_claim")
      "ready")
     (disconnect connection))))

(test-case "completion without signed bytes records no delivery evidence"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-paid-storage path))
     (define claimed
       (storage-claim-issuance-work! storage
                                     #:owner "worker-a"
                                     #:lease-seconds 30
                                     #:now 100))
     (storage-complete-issuance-work! storage claimed
                                      #:issuer issuer-name
                                      #:subject-type "person"
                                      #:entitlement-id "ent-001"
                                      #:credential-id "cred-001"
                                      #:policy-id "taskly-pro-v1"
                                      #:policy-version 1
                                      #:payload-bytes valid-payload
                                      #:issued-at "2026-10-21T00:00:00Z"
                                      #:recorded-at 120)
     (storage-close storage)
     (define connection (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_issued_credential")
      0)
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_claim")
      0)
     (disconnect connection))))

(test-case "the worker delivers a claimable signed credential end to end"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload (paid-event payload) #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define issuance-worker
       (make-issuance-worker
        #:catalog catalog
        #:issuer issuer-name
        #:private-key private-key
        #:key-id key-id
        #:trust-store trust-store
        #:clock (lambda ()
                  (values 100 "2026-10-21T00:00:00Z"))
        #:claim-window-seconds 1000))
     (define result (process-issuance-work! issuance-worker storage))
     (check-eq? (issuance-result-disposition result) 'completed)
     (define token (issuance-result-claim-token result))
     (check-true (and (string? token) (>= (string-length token) 32)))
     (storage-mark-claim-notified storage #:token token #:now 110)
     (define fulfillment
       (storage-claim-credential storage #:token token #:now 150))
     (define envelope
       (read-envelope
        (open-input-bytes
         (issued-credential-record-envelope-bytes
          (claim-fulfillment-credential fulfillment)))))
     (check-true (verify-envelope-signature envelope public-key))
     (check-equal?
      (hash-ref
       (with-input-from-bytes
           (permit-envelope-payload envelope)
         read-json)
       'entitlement_id)
      (issuance-result-entitlement-id result))
     (storage-close storage)
     (check-equal? (database-count path "commerce_issued_credential") 1)
     (check-equal? (database-count path "commerce_claim") 1))))
