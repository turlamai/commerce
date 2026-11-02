#lang racket/base

(require commerce
         commerce/journal
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         db
         file/sha1
         rackunit
         racket/file)

(define application-id 1129270605) ; ASCII "COMM"
(define usd-29 (money "USD" 2900))

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

(define (event payload
               #:event-id [event-id "evt_001"]
               #:kind [kind 'payment-succeeded]
               #:order-id [order-id "ord_001"]
               #:offer [offer-id "taskly-pro-lifetime"]
               #:subject [subject-id "customer-001"]
               #:amount [amount usd-29]
               #:occurred-at [occurred-at 1792108800])
  (make-verified-payment-event
   "mock" event-id (payload-digest payload) kind order-id offer-id subject-id
   amount occurred-at))

(define (delete-if-present path)
  (when (file-exists? path)
    (delete-file path)))

(define (call-with-temporary-database proc)
  (define path (make-temporary-file "commerce-storage-~a.sqlite"))
  (delete-file path)
  (dynamic-wind
    void
    (lambda () (proc path))
    (lambda ()
      (for ([suffix '("" "-shm" "-wal")])
        (delete-if-present
         (string->path (string-append (path->string path) suffix)))))))

(define (database-count path table)
  (define connection (sqlite3-connect #:database path #:mode 'read-only))
  (begin0
    (query-value connection (format "SELECT COUNT(*) FROM ~a" table))
    (disconnect connection)))

(test-case "schema v3 records immutable contiguous entitlement revisions"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload (event payload) #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define refund-payload #"authenticated refund")
     (journal-accept!
      storage refund-payload
      (event refund-payload #:event-id "evt_refund"
             #:kind 'payment-refunded #:occurred-at 12)
      #:received-at 13)
     (storage-project-next! storage #:processed-at 14)
     (storage-close storage)

     (define connection
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec connection "PRAGMA foreign_keys = ON")
     (check-equal? (query-value connection "PRAGMA user_version") 8)
     (check-equal?
      (query-value
       connection
       #<<SQL
SELECT COUNT(*)
FROM sqlite_master
WHERE type = 'trigger'
  AND name IN ('commerce_entitlement_lineage_no_update',
               'commerce_entitlement_lineage_no_delete',
               'commerce_entitlement_revision_no_update',
               'commerce_entitlement_revision_no_delete')
SQL
       )
      4)
     (query-exec
      connection
      #<<SQL
INSERT INTO commerce_entitlement_lineage
  (entitlement_id, issuer, subject_type, subject_id, credential_type, offer_id,
   created_at)
VALUES (?, ?, ?, ?, 'entitlement', ?, ?)
SQL
      "entitlement-001" "commerce.example" "person" "customer-001"
      "taskly-pro-lifetime" 12)
     (define initial-payload #"{\"revision\":0}")
     (query-exec
      connection
      #<<SQL
INSERT INTO commerce_entitlement_revision
  (entitlement_id, revision, previous_revision, credential_id,
   issuance_outbox_id, action, policy_id, policy_version, payload_bytes,
   payload_digest, issued_at, recorded_at)
VALUES (?, 0, NULL, ?, 1, 'grant', ?, 1, ?, ?, ?, ?)
SQL
      "entitlement-001" "credential-001" "taskly-pro-lifetime-v1"
      initial-payload (payload-digest initial-payload)
      "2026-10-17T03:00:00Z" 13)
     (check-equal?
      (query-row
       connection
       #<<SQL
SELECT l.issuer, l.subject_type, l.subject_id, l.offer_id, r.revision,
       r.previous_revision, r.credential_id, r.action, r.policy_id,
       r.policy_version, r.payload_bytes, r.payload_digest, r.issued_at
FROM commerce_entitlement_lineage AS l
JOIN commerce_entitlement_revision AS r
  ON r.entitlement_id = l.entitlement_id
SQL
       )
      (vector "commerce.example" "person" "customer-001"
              "taskly-pro-lifetime" 0 sql-null "credential-001" "grant"
              "taskly-pro-lifetime-v1" 1 initial-payload
              (payload-digest initial-payload) "2026-10-17T03:00:00Z"))
     (check-exn
      exn:fail:sql?
      (lambda ()
        (query-exec
         connection
         #<<SQL
INSERT INTO commerce_entitlement_revision
  (entitlement_id, revision, previous_revision, credential_id,
   issuance_outbox_id, action, policy_id, policy_version, payload_bytes,
   payload_digest, issued_at, recorded_at)
VALUES ('entitlement-001', 2, 1, 'credential-gap', 2, 'withdraw',
        'taskly-pro-lifetime-v1', 1, X'01', ?, '2026-10-17T03:01:00Z', 14)
SQL
         (make-string 64 #\a))))
     (define successor-payload #"{\"revision\":1}")
     (query-exec
      connection
      #<<SQL
INSERT INTO commerce_entitlement_revision
  (entitlement_id, revision, previous_revision, credential_id,
   issuance_outbox_id, action, policy_id, policy_version, payload_bytes,
   payload_digest, issued_at, recorded_at)
VALUES (?, 1, 0, ?, 2, 'withdraw', ?, 1, ?, ?, ?, ?)
SQL
      "entitlement-001" "credential-002" "taskly-pro-lifetime-v1"
      successor-payload (payload-digest successor-payload)
      "2026-10-17T03:01:00Z" 15)
     (check-equal?
      (query-value
       connection
       "SELECT COUNT(*) FROM commerce_entitlement_revision WHERE entitlement_id = 'entitlement-001'")
      2)
     (check-exn
      exn:fail:sql?
      (lambda ()
        (query-exec
         connection
         "UPDATE commerce_entitlement_revision SET policy_version = 2 WHERE entitlement_id = 'entitlement-001' AND revision = 0")))
     (check-exn
      exn:fail:sql?
      (lambda ()
        (query-exec
         connection
         "DELETE FROM commerce_entitlement_lineage WHERE entitlement_id = 'entitlement-001'")))
     (disconnect connection))))

(test-case "projection and issuance outbox commit as one durable transition"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment")
     (define paid (event payload))
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload paid #:received-at 1792108810)

     ;; Journal acknowledgement is the first durable phase. Projection remains
     ;; pending until the projector transaction runs.
     (check-equal? (database-count path "commerce_event_journal") 1)
     (check-equal? (database-count path "commerce_order_projection") 0)
     (check-equal? (database-count path "commerce_issuance_outbox") 0)

     (define result
       (storage-project-next! storage #:processed-at 1792108820))
     (check-eq? (projection-result-disposition result) 'projected)
     (check-equal? (projection-result-journal-sequence result) 1)
     (check-false (projection-result-failure-code result))
     (define projected-order (projection-result-order result))
     (check-true (order-projection-paid? projected-order))
     (check-false (order-projection-refunded? projected-order))
     (check-equal? (order-projection-paid-at projected-order) 1792108800)
     (check-equal? (length (projection-result-outbox result)) 1)

     (define work
       (storage-outbox-ref storage "mock/ord_001/grant"))
     (check-equal? work (car (projection-result-outbox result)))
     (check-equal? (issuance-outbox-item-id work) 1)
     (check-equal? (issuance-outbox-item-source-sequence work) 1)
     (check-eq? (issuance-outbox-item-action work) 'grant)
     (check-eq? (issuance-outbox-item-status work) 'pending)
     (check-equal? (issuance-outbox-item-attempts work) 0)
     (check-equal? (issuance-outbox-item-available-at work) 1792108820)
     (check-false (issuance-outbox-item-lease-owner work))
     (check-false (issuance-outbox-item-lease-expires-at work))
     (check-false (issuance-outbox-item-last-error-code work))
     (check-equal? (issuance-outbox-item-created-at work) 1792108820)
     (check-equal? (issuance-outbox-item-updated-at work) 1792108820)
     (check-false (issuance-outbox-item-completed-at work))
     (storage-close storage)

     ;; Reopening proves the returned transition was committed, not cached.
     (define reopened (open-sqlite-commerce-storage path))
     (check-equal? (storage-order-ref reopened "mock" "ord_001")
                   projected-order)
     (check-equal?
      (storage-outbox-ref reopened "mock/ord_001/grant")
      work)
     (check-false
      (storage-project-next! reopened #:processed-at 1792108830))
     (storage-close reopened)

     ;; Inspect emitted rows rather than trusting only public accessors.
     (define connection
       (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-row
       connection
       #<<SQL
SELECT provider, order_id, offer_id, subject_id, currency,
       amount_minor_units, paid, refunded, paid_at, refunded_at,
       last_event_sequence, updated_at
FROM commerce_order_projection
SQL
       )
      (vector "mock" "ord_001" "taskly-pro-lifetime" "customer-001"
              "USD" 2900 1 0 1792108800 sql-null 1 1792108820))
     (check-equal?
      (query-row
       connection
       #<<SQL
SELECT journal_sequence, status, failure_code, processed_at
FROM commerce_projection_event
SQL
       )
      (vector 1 "projected" sql-null 1792108820))
     (check-equal?
      (query-row
       connection
       #<<SQL
SELECT idempotency_key, source_journal_sequence, action, provider, order_id,
       offer_id, subject_id, occurred_at, status, attempts, available_at,
       lease_owner, lease_expires_at, last_error_code, created_at, updated_at,
       completed_at
FROM commerce_issuance_outbox
SQL
       )
      (vector "mock/ord_001/grant" 1 "grant" "mock" "ord_001"
              "taskly-pro-lifetime" "customer-001" 1792108800 "pending" 0
              1792108820 sql-null sql-null sql-null 1792108820 1792108820
              sql-null))
     (disconnect connection))))

(test-case "journal replay and projector replay never duplicate outbox work"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"same authenticated request")
     (define paid (event payload))
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload paid #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (define replay
       (journal-accept! storage payload paid #:received-at 12))
     (check-eq? (journal-acceptance-disposition replay) 'replayed)
     (check-false (storage-project-next! storage #:processed-at 13))
     (storage-close storage)
     (check-equal? (database-count path "commerce_event_journal") 1)
     (check-equal? (database-count path "commerce_projection_event") 1)
     (check-equal? (database-count path "commerce_issuance_outbox") 1))))

(test-case "failure between projection writes rolls the whole transaction back"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"payment before injected failure")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload (event payload) #:received-at 10)
     (storage-close storage)

     (define connection
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec
      connection
      #<<SQL
CREATE TRIGGER fail_outbox_insert
BEFORE INSERT ON commerce_issuance_outbox
BEGIN
  SELECT RAISE(ABORT, 'injected outbox failure');
END
SQL
      )
     (disconnect connection)

     (define failing (open-sqlite-commerce-storage path))
     (check-exn
      exn:fail:sql?
      (lambda ()
        (storage-project-next! failing #:processed-at 20)))
     (storage-close failing)
     (check-equal? (database-count path "commerce_order_projection") 0)
     (check-equal? (database-count path "commerce_issuance_outbox") 0)
     (check-equal? (database-count path "commerce_projection_event") 0)

     (define repair
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec repair "DROP TRIGGER fail_outbox_insert")
     (disconnect repair)
     (define retried (open-sqlite-commerce-storage path))
     (check-eq?
      (projection-result-disposition
       (storage-project-next! retried #:processed-at 21))
      'projected)
     (storage-close retried))))

(test-case "failure after outbox insertion rolls the whole transaction back"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"payment before marker failure")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload (event payload) #:received-at 10)
     (storage-close storage)

     (define connection
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec
      connection
      #<<SQL
CREATE TRIGGER fail_projection_marker_insert
BEFORE INSERT ON commerce_projection_event
BEGIN
  SELECT RAISE(ABORT, 'injected projection marker failure');
END
SQL
      )
     (disconnect connection)

     (define failing (open-sqlite-commerce-storage path))
     (check-exn
      exn:fail:sql?
      (lambda ()
        (storage-project-next! failing #:processed-at 20)))
     (storage-close failing)
     (check-equal? (database-count path "commerce_order_projection") 0)
     (check-equal? (database-count path "commerce_issuance_outbox") 0)
     (check-equal? (database-count path "commerce_projection_event") 0)

     (define repair
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec repair "DROP TRIGGER fail_projection_marker_insert")
     (disconnect repair)
     (define retried (open-sqlite-commerce-storage path))
     (check-eq?
      (projection-result-disposition
       (storage-project-next! retried #:processed-at 21))
      'projected)
     (storage-close retried))))

(test-case "order conflict is durably blocked without changing order or outbox"
  (call-with-temporary-database
   (lambda (path)
     (define first-payload #"first payment")
     (define conflict-payload #"conflicting payment")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage first-payload (event first-payload)
                      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (journal-accept!
      storage conflict-payload
      (event conflict-payload #:event-id "evt_002" #:subject "customer-002")
      #:received-at 12)
     (define blocked
       (storage-project-next! storage #:processed-at 13))
     (check-eq? (projection-result-disposition blocked) 'blocked)
     (check-eq? (projection-result-failure-code blocked) 'order-conflict)
     (check-equal? (order-projection-subject-id
                    (storage-order-ref storage "mock" "ord_001"))
                   "customer-001")
     (check-equal? (length (projection-result-outbox blocked)) 0)
     (check-false (storage-project-next! storage #:processed-at 14))
     (storage-close storage)
     (check-equal? (database-count path "commerce_order_projection") 1)
     (check-equal? (database-count path "commerce_issuance_outbox") 1)
     (define connection
       (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal?
      (query-row
       connection
       "SELECT journal_sequence, status, failure_code FROM commerce_projection_event ORDER BY journal_sequence DESC LIMIT 1")
      (vector 2 "blocked" "order-conflict"))
     (disconnect connection))))

(test-case "refund before payment persists both facts without grant work"
  (call-with-temporary-database
   (lambda (path)
     (define refund-payload #"refund arrived first")
     (define payment-payload #"payment arrived later")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept!
      storage refund-payload
      (event refund-payload #:event-id "evt_refund"
             #:kind 'payment-refunded #:occurred-at 20)
      #:received-at 21)
     (define refund-result
       (storage-project-next! storage #:processed-at 22))
     (check-equal? (projection-result-outbox refund-result) '())
     (journal-accept!
      storage payment-payload
      (event payment-payload #:event-id "evt_payment" #:occurred-at 10)
      #:received-at 23)
     (define payment-result
       (storage-project-next! storage #:processed-at 24))
     (check-equal? (projection-result-outbox payment-result) '())
     (define order (storage-order-ref storage "mock" "ord_001"))
     (check-true (order-projection-paid? order))
     (check-true (order-projection-refunded? order))
     (check-equal? (order-projection-paid-at order) 10)
     (check-equal? (order-projection-refunded-at order) 20)
     (storage-close storage)
     (check-equal? (database-count path "commerce_issuance_outbox") 0))))

(test-case "refund after payment emits one durable withdrawal intent"
  (call-with-temporary-database
   (lambda (path)
     (define payment-payload #"payment first")
     (define refund-payload #"refund second")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payment-payload (event payment-payload)
                      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (journal-accept!
      storage refund-payload
      (event refund-payload #:event-id "evt_refund"
             #:kind 'payment-refunded #:occurred-at 20)
      #:received-at 21)
     (define result
       (storage-project-next! storage #:processed-at 22))
     (check-eq? (projection-result-disposition result) 'projected)
     (check-equal? (length (projection-result-outbox result)) 1)
     (define withdrawal
       (storage-outbox-ref storage "mock/ord_001/withdraw"))
     (check-eq? (issuance-outbox-item-action withdrawal) 'withdraw)
     (check-equal? (issuance-outbox-item-source-sequence withdrawal) 2)
     (check-eq? (issuance-outbox-item-status withdrawal) 'pending)
     (define order (storage-order-ref storage "mock" "ord_001"))
     (check-true (order-projection-paid? order))
     (check-true (order-projection-refunded? order))
     (storage-close storage)
     (check-equal? (database-count path "commerce_issuance_outbox") 2))))

(define (create-v1-database path payload)
  (define connection
    (sqlite3-connect #:database path #:mode 'create))
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_event_journal (
  sequence INTEGER PRIMARY KEY,
  provider TEXT NOT NULL,
  event_id TEXT NOT NULL,
  raw_payload BLOB NOT NULL,
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  event_kind TEXT NOT NULL
    CHECK (event_kind IN ('payment-succeeded', 'payment-refunded')),
  order_id TEXT NOT NULL,
  offer_id TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  currency TEXT NOT NULL CHECK (length(currency) = 3),
  amount_minor_units INTEGER NOT NULL CHECK (amount_minor_units >= 0),
  occurred_at INTEGER NOT NULL CHECK (occurred_at >= 0),
  received_at INTEGER NOT NULL CHECK (received_at >= 0),
  UNIQUE (provider, event_id)
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TRIGGER commerce_event_journal_no_update
BEFORE UPDATE ON commerce_event_journal
BEGIN
  SELECT RAISE(ABORT, 'commerce event journal rows are immutable');
END
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TRIGGER commerce_event_journal_no_delete
BEFORE DELETE ON commerce_event_journal
BEGIN
  SELECT RAISE(ABORT, 'commerce event journal rows are immutable');
END
SQL
   )
  (query-exec
   connection
   #<<SQL
INSERT INTO commerce_event_journal
  (provider, event_id, raw_payload, payload_digest, event_kind, order_id,
   offer_id, subject_id, currency, amount_minor_units, occurred_at, received_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
   "mock" "evt_001" payload (payload-digest payload) "payment-succeeded"
   "ord_001" "taskly-pro-lifetime" "customer-001" "USD" 2900
   1792108800 1792108810)
  (query-exec connection (format "PRAGMA application_id = ~a" application-id))
  (query-exec connection "PRAGMA user_version = 1")
  (disconnect connection))

(test-case "schema v1 migrates in place and preserves pending journal evidence"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"accepted by schema v1")
     (create-v1-database path payload)
     (define storage (open-sqlite-commerce-storage path))
     (check-equal?
      (journal-record-payload (journal-ref storage "mock" "evt_001"))
      payload)
     (check-eq?
      (projection-result-disposition
       (storage-project-next! storage #:processed-at 1792108820))
      'projected)
     (storage-close storage)
     (define connection
       (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal? (query-value connection "PRAGMA user_version") 8)
     (check-equal?
      (query-value
       connection
       "SELECT raw_payload FROM commerce_event_journal WHERE sequence = 1")
      payload)
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_issuance_outbox")
      1)
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_entitlement_lineage")
      0)
     (disconnect connection))))

(test-case "schema v2 migrates in place without changing durable work"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"schema v2 durable evidence")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept! storage payload (event payload) #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (storage-close storage)

     ;; Remove the v3 and v4 tables to reproduce the exact v2 structural
     ;; subset.
     (define old
       (sqlite3-connect #:database path #:mode 'read/write))
     (query-exec old "DROP TABLE commerce_operator_audit")
     (query-exec old "DROP TABLE commerce_claim")
     (query-exec old "DROP TABLE commerce_issued_credential")
     (query-exec old "DROP TABLE commerce_checkout_binding")
     (query-exec old "DROP TABLE commerce_entitlement_revision")
     (query-exec old "DROP TABLE commerce_entitlement_lineage")
     (query-exec old "ALTER TABLE commerce_event_journal DROP COLUMN paid_through")
     (query-exec old "ALTER TABLE commerce_event_journal DROP COLUMN signature_evidence")
     (query-exec old "PRAGMA user_version = 2")
     (define before
       (query-row
        old
        "SELECT idempotency_key, source_journal_sequence, status, attempts, available_at FROM commerce_issuance_outbox"))
     (disconnect old)

     (define migrated (open-sqlite-commerce-storage path))
     (storage-close migrated)
     (define connection
       (sqlite3-connect #:database path #:mode 'read-only))
     (check-equal? (query-value connection "PRAGMA user_version") 8)
     (check-equal?
      (query-row
       connection
       "SELECT idempotency_key, source_journal_sequence, status, attempts, available_at FROM commerce_issuance_outbox")
      before)
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_entitlement_lineage")
      0)
     (check-equal?
      (query-value connection "SELECT COUNT(*) FROM commerce_entitlement_revision")
      0)
     (disconnect connection))))
