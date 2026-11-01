#lang racket/base

(provide open-sqlite-commerce-storage)

(require db
         file/sha1
         racket/match
         "../private/journal-model.rkt"
         "../private/model.rkt"
         "../private/projection.rkt"
         "../private/storage-model.rkt")

(define schema-version 7)
(define application-id 1129270605) ; ASCII "COMM"
(define sqlite-max-integer 9223372036854775807)

(define select-record-sql
  #<<SQL
SELECT sequence, provider, event_id, raw_payload, payload_digest, event_kind,
       order_id, offer_id, subject_id, currency, amount_minor_units,
       occurred_at, received_at, paid_through
FROM commerce_event_journal
WHERE provider = ? AND event_id = ?
SQL
  )

(define select-next-unprojected-sql
  #<<SQL
SELECT j.sequence, j.provider, j.event_id, j.raw_payload, j.payload_digest,
       j.event_kind, j.order_id, j.offer_id, j.subject_id, j.currency,
       j.amount_minor_units, j.occurred_at, j.received_at, j.paid_through
FROM commerce_event_journal AS j
LEFT JOIN commerce_projection_event AS p
  ON p.journal_sequence = j.sequence
WHERE p.journal_sequence IS NULL
ORDER BY j.sequence
LIMIT 1
SQL
  )

(define select-order-sql
  #<<SQL
SELECT provider, order_id, offer_id, subject_id, currency,
       amount_minor_units, paid, refunded, paid_at, refunded_at, paid_through
FROM commerce_order_projection
WHERE provider = ? AND order_id = ?
SQL
  )

(define select-outbox-sql
  #<<SQL
SELECT id, idempotency_key, source_journal_sequence, action, provider,
       order_id, offer_id, subject_id, occurred_at, status, attempts,
       available_at, lease_owner, lease_expires_at, last_error_code,
       created_at, updated_at, completed_at
FROM commerce_issuance_outbox
WHERE idempotency_key = ?
SQL
  )

(define select-lineage-sql
  #<<SQL
SELECT entitlement_id, issuer, subject_type, subject_id, offer_id, created_at
FROM commerce_entitlement_lineage
WHERE entitlement_id = ?
SQL
  )

(define select-lineage-identity-sql
  #<<SQL
SELECT entitlement_id, created_at
FROM commerce_entitlement_lineage
WHERE issuer = ? AND subject_type = ? AND subject_id = ?
  AND credential_type = 'entitlement' AND offer_id = ?
SQL
  )

(define revision-columns-sql
  "entitlement_id, revision, previous_revision, credential_id,
   issuance_outbox_id, action, policy_id, policy_version, payload_bytes,
   payload_digest, issued_at, recorded_at")

(define select-revision-sql
  (string-append
   "SELECT " revision-columns-sql
   " FROM commerce_entitlement_revision WHERE entitlement_id = ? AND revision = ?"))

(define select-latest-revision-sql
  (string-append
   "SELECT " revision-columns-sql
   " FROM commerce_entitlement_revision WHERE entitlement_id = ?"
   " ORDER BY revision DESC LIMIT 1"))

(define select-revision-by-outbox-sql
  (string-append
   "SELECT " revision-columns-sql
   " FROM commerce_entitlement_revision WHERE issuance_outbox_id = ?"))

(define select-outbox-scan-sql
  #<<SQL
SELECT id, idempotency_key, source_journal_sequence, action, provider,
       order_id, offer_id, subject_id, occurred_at, status, attempts,
       available_at, lease_owner, lease_expires_at, last_error_code,
       created_at, updated_at, completed_at
FROM commerce_issuance_outbox
ORDER BY id
SQL
  )

(define select-order-journal-sql
  #<<SQL
SELECT sequence, provider, event_id, raw_payload, payload_digest, event_kind,
       order_id, offer_id, subject_id, currency, amount_minor_units,
       occurred_at, received_at, paid_through
FROM commerce_event_journal
WHERE provider = ? AND order_id = ?
ORDER BY sequence
SQL
  )

(define select-order-outbox-sql
  #<<SQL
SELECT id, idempotency_key, source_journal_sequence, action, provider,
       order_id, offer_id, subject_id, occurred_at, status, attempts,
       available_at, lease_owner, lease_expires_at, last_error_code,
       created_at, updated_at, completed_at
FROM commerce_issuance_outbox
WHERE provider = ? AND order_id = ?
ORDER BY id
SQL
  )

(define select-issued-credential-sql
  #<<SQL
SELECT id, issuance_outbox_id, entitlement_id, revision, credential_id,
       key_id, envelope_bytes, created_at
FROM commerce_issued_credential
WHERE issuance_outbox_id = ?
SQL
  )

;; A refund is unresolved until its exact authenticated journal event has
;; produced an issued withdrawal revision. This also detects journaled
;; refunds not yet projected into outbox work.
(define select-unresolved-refund-sql
  #<<SQL
SELECT EXISTS (
  SELECT 1
  FROM commerce_event_journal AS j
  WHERE j.subject_id = ? AND j.offer_id = ?
    AND j.event_kind = 'payment-refunded'
    AND NOT EXISTS (
      SELECT 1
      FROM commerce_issuance_outbox AS o
      JOIN commerce_entitlement_revision AS r
        ON r.issuance_outbox_id = o.id
      WHERE o.source_journal_sequence = j.sequence
        AND o.action = 'withdraw'
    )
)
SQL
  )

(define select-readiness-sql
  #<<SQL
SELECT
  (SELECT COUNT(*) FROM commerce_event_journal),
  (SELECT COUNT(*) FROM commerce_event_journal AS j
     LEFT JOIN commerce_projection_event AS p
       ON p.journal_sequence = j.sequence
    WHERE p.journal_sequence IS NULL),
  (SELECT COUNT(*) FROM commerce_projection_event WHERE status = 'blocked'),
  (SELECT COUNT(*) FROM commerce_issuance_outbox WHERE status = 'pending'),
  (SELECT COUNT(*) FROM commerce_issuance_outbox WHERE status = 'processing'),
  (SELECT COUNT(*) FROM commerce_issuance_outbox
     WHERE status = 'processing' AND lease_expires_at <= ?1),
  (SELECT MIN(available_at) FROM commerce_issuance_outbox
     WHERE status = 'pending'),
  (SELECT COUNT(*) FROM commerce_claim WHERE status = 'ready'),
  (SELECT COUNT(*) FROM commerce_claim WHERE status = 'claimed'),
  (SELECT COUNT(*) FROM commerce_claim
     WHERE status = 'ready' AND expires_at <= ?1)
SQL
  )

(define select-due-work-sql
  #<<SQL
SELECT id, idempotency_key
FROM commerce_issuance_outbox
WHERE (status = 'pending' AND available_at <= ?)
   OR (status = 'processing' AND lease_expires_at <= ?)
ORDER BY id
LIMIT 1
SQL
  )

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (nullable value)
  (if (sql-null? value) #f value))

(define (sql-nullable value)
  (if value value sql-null))

(define (row->record row)
  (match-define
    (vector sequence provider event-id payload payload-digest event-kind
            order-id offer-id subject-id currency amount-minor-units
            occurred-at received-at paid-through)
    row)
  (journal-record
   sequence
   (payment-event provider event-id payload-digest
                  (string->symbol event-kind)
                  order-id offer-id subject-id
                  (money currency amount-minor-units)
                  occurred-at
                  (nullable paid-through))
   (bytes->immutable-bytes payload)
   received-at))

(define (row->order row)
  (and row
       (match-let ([(vector provider order-id offer-id subject-id currency
                            amount-minor-units paid refunded paid-at
                            refunded-at paid-through)
                    row])
         (order-projection
          provider order-id offer-id subject-id
          (money currency amount-minor-units)
          (= paid 1) (= refunded 1)
          (nullable paid-at) (nullable refunded-at)
          (nullable paid-through)))))

(define (row->outbox row)
  (and row
       (match-let ([(vector id idempotency-key source-sequence action provider
                            order-id offer-id subject-id occurred-at status
                            attempts available-at lease-owner lease-expires-at
                            last-error-code created-at updated-at completed-at)
                    row])
         (issuance-outbox-item
          id idempotency-key source-sequence (string->symbol action)
          provider order-id offer-id subject-id occurred-at
          (string->symbol status) attempts available-at
          (nullable lease-owner) (nullable lease-expires-at)
          (and (not (sql-null? last-error-code))
               (string->symbol last-error-code))
          created-at updated-at (nullable completed-at)))))

(define (row->lineage row)
  (and row
       (match-let ([(vector entitlement-id issuer subject-type subject-id
                            offer-id created-at)
                    row])
         (entitlement-lineage
          entitlement-id issuer subject-type subject-id offer-id
          created-at))))

(define (row->revision row)
  (and row
       (match-let ([(vector entitlement-id revision previous-revision
                            credential-id issuance-outbox-id action policy-id
                            policy-version payload-bytes payload-digest
                            issued-at recorded-at)
                    row])
         (entitlement-revision
          entitlement-id revision (nullable previous-revision)
          credential-id issuance-outbox-id (string->symbol action)
          policy-id policy-version
          (bytes->immutable-bytes payload-bytes) payload-digest
          issued-at recorded-at))))

(define (lookup-record connection provider event-id)
  (define row
    (query-maybe-row connection select-record-sql provider event-id))
  (and row (row->record row)))

(define (lookup-order connection provider order-id)
  (row->order
   (query-maybe-row connection select-order-sql provider order-id)))

(define (lookup-outbox connection idempotency-key)
  (row->outbox
   (query-maybe-row connection select-outbox-sql idempotency-key)))

(define (lookup-lineage connection entitlement-id)
  (row->lineage
   (query-maybe-row connection select-lineage-sql entitlement-id)))

(define (lookup-revision connection entitlement-id revision)
  (row->revision
   (query-maybe-row connection select-revision-sql entitlement-id revision)))

(define (lookup-issued-credential connection issuance-outbox-id)
  (define row
    (query-maybe-row
     connection select-issued-credential-sql issuance-outbox-id))
  (and row
       (match-let ([(vector id outbox-id entitlement-id revision
                            credential-id envelope-key-id envelope-bytes
                            created-at)
                    row])
         (issued-credential-record
          id outbox-id entitlement-id revision credential-id envelope-key-id
          (bytes->immutable-bytes envelope-bytes) created-at))))

(define (record-content=? record payload event)
  (and (equal? (journal-record-payload record) payload)
       (equal? (journal-record-event record) event)))

(define (check-sqlite-integer field value [event #f])
  (unless (<= value sqlite-max-integer)
    (raise-commerce
     'persistence-value-out-of-range
     "storage value exceeds SQLite's signed 64-bit integer range"
     (if event
         (hash 'provider (payment-event-provider event)
               'event-id (payment-event-event-id event)
               'field field)
         (hash 'field field)))))

(define (create-journal-schema! connection)
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
  paid_through INTEGER CHECK (paid_through >= 0),
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
   ))

(define (create-projection-schema! connection)
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_order_projection (
  provider TEXT NOT NULL,
  order_id TEXT NOT NULL,
  offer_id TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  currency TEXT NOT NULL CHECK (length(currency) = 3),
  amount_minor_units INTEGER NOT NULL CHECK (amount_minor_units >= 0),
  paid INTEGER NOT NULL CHECK (paid IN (0, 1)),
  refunded INTEGER NOT NULL CHECK (refunded IN (0, 1)),
  paid_at INTEGER CHECK (paid_at >= 0),
  refunded_at INTEGER CHECK (refunded_at >= 0),
  paid_through INTEGER CHECK (paid_through >= 0),
  last_event_sequence INTEGER NOT NULL,
  updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
  PRIMARY KEY (provider, order_id),
  FOREIGN KEY (last_event_sequence)
    REFERENCES commerce_event_journal(sequence),
  CHECK ((paid = 0 AND paid_at IS NULL) OR
         (paid = 1 AND paid_at IS NOT NULL)),
  CHECK ((refunded = 0 AND refunded_at IS NULL) OR
         (refunded = 1 AND refunded_at IS NOT NULL))
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_projection_event (
  journal_sequence INTEGER PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('projected', 'blocked')),
  failure_code TEXT,
  processed_at INTEGER NOT NULL CHECK (processed_at >= 0),
  FOREIGN KEY (journal_sequence)
    REFERENCES commerce_event_journal(sequence),
  CHECK ((status = 'projected' AND failure_code IS NULL) OR
         (status = 'blocked' AND failure_code IS NOT NULL))
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_issuance_outbox (
  id INTEGER PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  source_journal_sequence INTEGER NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('grant', 'withdraw')),
  provider TEXT NOT NULL,
  order_id TEXT NOT NULL,
  offer_id TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  occurred_at INTEGER NOT NULL CHECK (occurred_at >= 0),
  status TEXT NOT NULL
    CHECK (status IN ('pending', 'processing', 'completed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at INTEGER NOT NULL CHECK (available_at >= 0),
  lease_owner TEXT,
  lease_expires_at INTEGER CHECK (lease_expires_at >= 0),
  last_error_code TEXT,
  created_at INTEGER NOT NULL CHECK (created_at >= 0),
  updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
  completed_at INTEGER CHECK (completed_at >= 0),
  FOREIGN KEY (source_journal_sequence)
    REFERENCES commerce_event_journal(sequence),
  CHECK ((status = 'processing' AND lease_owner IS NOT NULL AND
          lease_expires_at IS NOT NULL) OR
         (status <> 'processing' AND lease_owner IS NULL AND
          lease_expires_at IS NULL)),
  CHECK ((status = 'completed' AND completed_at IS NOT NULL) OR
         (status <> 'completed' AND completed_at IS NULL))
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE INDEX commerce_issuance_outbox_ready
ON commerce_issuance_outbox(status, available_at, id)
SQL
   ))

(define (create-lineage-schema! connection)
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_entitlement_lineage (
  entitlement_id TEXT PRIMARY KEY
    CHECK (length(entitlement_id) BETWEEN 1 AND 256),
  issuer TEXT NOT NULL CHECK (length(issuer) BETWEEN 1 AND 256),
  subject_type TEXT NOT NULL CHECK (length(subject_type) BETWEEN 1 AND 256),
  subject_id TEXT NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 256),
  credential_type TEXT NOT NULL CHECK (credential_type = 'entitlement'),
  offer_id TEXT NOT NULL CHECK (length(offer_id) BETWEEN 1 AND 256),
  created_at INTEGER NOT NULL CHECK (created_at >= 0),
  UNIQUE (issuer, subject_type, subject_id, credential_type, offer_id)
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_entitlement_revision (
  entitlement_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision >= 0),
  previous_revision INTEGER CHECK (previous_revision >= 0),
  credential_id TEXT NOT NULL UNIQUE
    CHECK (length(credential_id) BETWEEN 1 AND 256),
  issuance_outbox_id INTEGER NOT NULL UNIQUE,
  action TEXT NOT NULL CHECK (action IN ('grant', 'withdraw')),
  policy_id TEXT NOT NULL CHECK (length(policy_id) BETWEEN 1 AND 256),
  policy_version INTEGER NOT NULL CHECK (policy_version > 0),
  payload_bytes BLOB NOT NULL CHECK (length(payload_bytes) > 0),
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  issued_at TEXT NOT NULL CHECK (length(issued_at) > 0),
  recorded_at INTEGER NOT NULL CHECK (recorded_at >= 0),
  PRIMARY KEY (entitlement_id, revision),
  FOREIGN KEY (entitlement_id)
    REFERENCES commerce_entitlement_lineage(entitlement_id),
  FOREIGN KEY (issuance_outbox_id)
    REFERENCES commerce_issuance_outbox(id),
  FOREIGN KEY (entitlement_id, previous_revision)
    REFERENCES commerce_entitlement_revision(entitlement_id, revision),
  CHECK ((revision = 0 AND previous_revision IS NULL AND action = 'grant') OR
         (revision > 0 AND previous_revision = revision - 1))
)
SQL
   )
  (for ([statement
         (in-list
          (list
           #<<SQL
CREATE TRIGGER commerce_entitlement_lineage_no_update
BEFORE UPDATE ON commerce_entitlement_lineage
BEGIN
  SELECT RAISE(ABORT, 'commerce entitlement lineage rows are immutable');
END
SQL
           #<<SQL
CREATE TRIGGER commerce_entitlement_lineage_no_delete
BEFORE DELETE ON commerce_entitlement_lineage
BEGIN
  SELECT RAISE(ABORT, 'commerce entitlement lineage rows are immutable');
END
SQL
           #<<SQL
CREATE TRIGGER commerce_entitlement_revision_no_update
BEFORE UPDATE ON commerce_entitlement_revision
BEGIN
  SELECT RAISE(ABORT, 'commerce entitlement revision rows are immutable');
END
SQL
           #<<SQL
CREATE TRIGGER commerce_entitlement_revision_no_delete
BEFORE DELETE ON commerce_entitlement_revision
BEGIN
  SELECT RAISE(ABORT, 'commerce entitlement revision rows are immutable');
END
SQL
           ))])
    (query-exec connection statement)))

;; Schema v4 adds the delivery half of issuance. The issued-credential table
;; retains the exact signed envelope bytes an append-only audit record; the
;; claim table tracks one-time fulfillment state and stores only the claim
;; token digest, never the token itself.
(define (create-delivery-schema! connection)
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_issued_credential (
  id INTEGER PRIMARY KEY,
  issuance_outbox_id INTEGER NOT NULL UNIQUE,
  entitlement_id TEXT NOT NULL
    CHECK (length(entitlement_id) BETWEEN 1 AND 256),
  revision INTEGER NOT NULL CHECK (revision >= 0),
  credential_id TEXT NOT NULL UNIQUE
    CHECK (length(credential_id) BETWEEN 1 AND 256),
  key_id TEXT NOT NULL CHECK (length(key_id) BETWEEN 1 AND 256),
  envelope_bytes BLOB NOT NULL CHECK (length(envelope_bytes) > 0),
  created_at INTEGER NOT NULL CHECK (created_at >= 0),
  FOREIGN KEY (issuance_outbox_id)
    REFERENCES commerce_issuance_outbox(id),
  FOREIGN KEY (entitlement_id, revision)
    REFERENCES commerce_entitlement_revision(entitlement_id, revision)
)
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_claim (
  id INTEGER PRIMARY KEY,
  claim_token_digest TEXT NOT NULL UNIQUE
    CHECK (length(claim_token_digest) = 64),
  issued_credential_id INTEGER NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('ready', 'claimed', 'expired')),
  notified_at INTEGER CHECK (notified_at >= 0),
  claimed_at INTEGER CHECK (claimed_at >= 0),
  expires_at INTEGER NOT NULL CHECK (expires_at >= 0),
  created_at INTEGER NOT NULL CHECK (created_at >= 0),
  updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
  FOREIGN KEY (issued_credential_id)
    REFERENCES commerce_issued_credential(id),
  CHECK ((status = 'claimed' AND claimed_at IS NOT NULL) OR
         (status IN ('ready', 'expired') AND claimed_at IS NULL))
)
SQL
   )
  (for ([statement
         (in-list
          (list
           #<<SQL
CREATE TRIGGER commerce_issued_credential_no_update
BEFORE UPDATE ON commerce_issued_credential
BEGIN
  SELECT RAISE(ABORT, 'commerce issued credential rows are immutable');
END
SQL
           #<<SQL
CREATE TRIGGER commerce_issued_credential_no_delete
BEFORE DELETE ON commerce_issued_credential
BEGIN
  SELECT RAISE(ABORT, 'commerce issued credential rows are immutable');
END
SQL
           #<<SQL
CREATE TRIGGER commerce_claim_no_delete
BEFORE DELETE ON commerce_claim
BEGIN
  SELECT RAISE(ABORT, 'commerce claim rows are immutable');
END
SQL
           ))])
    (query-exec connection statement)))

(define (create-checkout-binding-schema! connection)
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_checkout_binding (
  merchant_external_id TEXT PRIMARY KEY
    CHECK (length(merchant_external_id) BETWEEN 1 AND 128),
  provider TEXT NOT NULL CHECK (length(provider) BETWEEN 1 AND 256),
  product_id TEXT NOT NULL CHECK (length(product_id) BETWEEN 1 AND 256),
  offer_id TEXT NOT NULL CHECK (length(offer_id) BETWEEN 1 AND 256),
  subject_id TEXT NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 256),
  currency TEXT NOT NULL CHECK (length(currency) = 3),
  amount_minor_units INTEGER NOT NULL CHECK (amount_minor_units >= 0),
  currency_exponent INTEGER NOT NULL
    CHECK (currency_exponent BETWEEN 0 AND 4),
  created_at INTEGER NOT NULL CHECK (created_at >= 0)
)
SQL
   )
  (for ([statement
         (in-list
          (list
           #<<SQL
CREATE TRIGGER commerce_checkout_binding_no_update
BEFORE UPDATE ON commerce_checkout_binding
BEGIN
  SELECT RAISE(ABORT, 'commerce checkout binding rows are immutable');
END
SQL
           #<<SQL
CREATE TRIGGER commerce_checkout_binding_no_delete
BEFORE DELETE ON commerce_checkout_binding
BEGIN
  SELECT RAISE(ABORT, 'commerce checkout binding rows are immutable');
END
SQL
           ))])
    (query-exec connection statement)))

(define (create-audit-schema! connection)
  ;; Reissue appends one claim per re-grant for the same credential, so the
  ;; v7 migration rebuilds the claim table without the single-claim-per-
  ;; credential uniqueness. Prior rows are preserved as audit evidence.
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_claim_v7 (
  id INTEGER PRIMARY KEY,
  claim_token_digest TEXT NOT NULL UNIQUE
    CHECK (length(claim_token_digest) = 64),
  issued_credential_id INTEGER NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('ready', 'claimed', 'expired')),
  notified_at INTEGER CHECK (notified_at >= 0),
  claimed_at INTEGER CHECK (claimed_at >= 0),
  expires_at INTEGER NOT NULL CHECK (expires_at >= 0),
  created_at INTEGER NOT NULL CHECK (created_at >= 0),
  updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
  FOREIGN KEY (issued_credential_id)
    REFERENCES commerce_issued_credential(id),
  CHECK ((status = 'claimed' AND claimed_at IS NOT NULL) OR
         (status IN ('ready', 'expired') AND claimed_at IS NULL))
)
SQL
   )
  (query-exec
   connection
   "INSERT INTO commerce_claim_v7
  (id, claim_token_digest, issued_credential_id, status, notified_at,
   claimed_at, expires_at, created_at, updated_at)
SELECT id, claim_token_digest, issued_credential_id, status, notified_at,
       claimed_at, expires_at, created_at, updated_at FROM commerce_claim")
  (query-exec connection "DROP TABLE commerce_claim")
  (query-exec
   connection
   "ALTER TABLE commerce_claim_v7 RENAME TO commerce_claim")
  (query-exec
   connection
   #<<SQL
CREATE TRIGGER commerce_claim_no_delete
BEFORE DELETE ON commerce_claim
BEGIN
  SELECT RAISE(ABORT, 'commerce claim rows are immutable');
END
SQL
   )
  (query-exec
   connection
   #<<SQL
CREATE TABLE commerce_operator_audit (
  id INTEGER PRIMARY KEY,
  action TEXT NOT NULL CHECK (length(action) BETWEEN 1 AND 128),
  operator TEXT NOT NULL CHECK (length(operator) BETWEEN 1 AND 256),
  reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 4096),
  subject TEXT NOT NULL CHECK (length(subject) BETWEEN 1 AND 256),
  created_at INTEGER NOT NULL CHECK (created_at >= 0)
)
SQL
   )
  (for ([statement
         (in-list
          (list
           #<<SQL
CREATE TRIGGER commerce_operator_audit_no_update
BEFORE UPDATE ON commerce_operator_audit
BEGIN
  SELECT RAISE(ABORT, 'commerce operator audit rows are immutable');
END
SQL
           #<<SQL
CREATE TRIGGER commerce_operator_audit_no_delete
BEFORE DELETE ON commerce_operator_audit
BEGIN
  SELECT RAISE(ABORT, 'commerce operator audit rows are immutable');
END
SQL
           ))])
    (query-exec connection statement)))

(define (initialize-schema! connection)
  (define stored-application-id
    (query-value connection "PRAGMA application_id"))
  (define stored-version
    (query-value connection "PRAGMA user_version"))
  (cond
    [(and (= stored-application-id 0) (= stored-version 0))
     (call-with-transaction
      connection
      (lambda ()
        (create-journal-schema! connection)
        (create-projection-schema! connection)
        (create-lineage-schema! connection)
        (create-delivery-schema! connection)
        (create-checkout-binding-schema! connection)
        (create-audit-schema! connection)
        (query-exec connection
                    (format "PRAGMA application_id = ~a" application-id))
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(not (= stored-application-id application-id))
     (raise-commerce
      'database-identity-conflict
      "SQLite database does not belong to Commerce"
      (hash 'application-id stored-application-id))]
    [(= stored-version 1)
     (call-with-transaction
      connection
      (lambda ()
        (query-exec connection
                    "ALTER TABLE commerce_event_journal ADD COLUMN paid_through INTEGER CHECK (paid_through >= 0)")
        (create-projection-schema! connection)
        (create-lineage-schema! connection)
        (create-delivery-schema! connection)
        (create-checkout-binding-schema! connection)
        (create-audit-schema! connection)
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(= stored-version 2)
     (call-with-transaction
      connection
      (lambda ()
        (query-exec connection
                    "ALTER TABLE commerce_event_journal ADD COLUMN paid_through INTEGER CHECK (paid_through >= 0)")
        (create-lineage-schema! connection)
        (create-delivery-schema! connection)
        (create-checkout-binding-schema! connection)
        (create-audit-schema! connection)
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(= stored-version 4)
     (call-with-transaction
      connection
      (lambda ()
        (query-exec connection
                    "ALTER TABLE commerce_event_journal ADD COLUMN paid_through INTEGER CHECK (paid_through >= 0)")
        (query-exec connection
                    "ALTER TABLE commerce_order_projection ADD COLUMN paid_through INTEGER CHECK (paid_through >= 0)")
        (create-checkout-binding-schema! connection)
        (create-audit-schema! connection)
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(= stored-version 5)
     (call-with-transaction
      connection
      (lambda ()
        (create-checkout-binding-schema! connection)
        (create-audit-schema! connection)
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(= stored-version 6)
     (call-with-transaction
      connection
      (lambda ()
        (create-audit-schema! connection)
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(= stored-version 3)
     (call-with-transaction
      connection
      (lambda ()
        (create-delivery-schema! connection)
        (create-checkout-binding-schema! connection)
        (create-audit-schema! connection)
        (query-exec connection
                    "ALTER TABLE commerce_event_journal ADD COLUMN paid_through INTEGER CHECK (paid_through >= 0)")
        (query-exec connection
                    "ALTER TABLE commerce_order_projection ADD COLUMN paid_through INTEGER CHECK (paid_through >= 0)")
        (query-exec connection
                    (format "PRAGMA user_version = ~a" schema-version)))
      #:option 'immediate)]
    [(not (= stored-version schema-version))
     (raise-commerce
      'unsupported-schema-version
      "Commerce storage schema version is unsupported"
      (hash 'expected schema-version 'actual stored-version))]))

(define (write-order! connection order journal-sequence processed-at)
  (query-exec
   connection
   #<<SQL
INSERT INTO commerce_order_projection
  (provider, order_id, offer_id, subject_id, currency, amount_minor_units,
   paid, refunded, paid_at, refunded_at, paid_through, last_event_sequence,
   updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(provider, order_id) DO UPDATE SET
  offer_id = excluded.offer_id,
  subject_id = excluded.subject_id,
  currency = excluded.currency,
  amount_minor_units = excluded.amount_minor_units,
  paid = excluded.paid,
  refunded = excluded.refunded,
  paid_at = excluded.paid_at,
  refunded_at = excluded.refunded_at,
  paid_through = excluded.paid_through,
  last_event_sequence = excluded.last_event_sequence,
  updated_at = excluded.updated_at
SQL
   (order-projection-provider order)
   (order-projection-order-id order)
   (order-projection-offer-id order)
   (order-projection-subject-id order)
   (money-currency (order-projection-amount order))
   (money-minor-units (order-projection-amount order))
   (if (order-projection-paid? order) 1 0)
   (if (order-projection-refunded? order) 1 0)
   (sql-nullable (order-projection-paid-at order))
   (sql-nullable (order-projection-refunded-at order))
   (sql-nullable (order-projection-paid-through order))
   journal-sequence
   processed-at))

(define (write-outbox! connection intent journal-sequence processed-at)
  (query-exec
   connection
   #<<SQL
INSERT INTO commerce_issuance_outbox
  (idempotency_key, source_journal_sequence, action, provider, order_id,
   offer_id, subject_id, occurred_at, status, attempts, available_at,
   lease_owner, lease_expires_at, last_error_code, created_at, updated_at,
   completed_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, NULL, NULL, NULL, ?, ?, NULL)
SQL
   (rights-intent-idempotency-key intent)
   journal-sequence
   (symbol->string (rights-intent-action intent))
   (rights-intent-provider intent)
   (rights-intent-order-id intent)
   (rights-intent-offer-id intent)
   (rights-intent-subject-id intent)
   (rights-intent-occurred-at intent)
   processed-at processed-at processed-at)
  (lookup-outbox connection (rights-intent-idempotency-key intent)))

(define (open-sqlite-commerce-storage database)
  (unless (path-string? database)
    (raise-argument-error
     'open-sqlite-commerce-storage "path-string?" database))
  (define connection
    (sqlite3-connect
     #:database database
     #:mode 'create
     #:busy-retry-delay 0.05
     #:busy-retry-limit 40))
  (with-handlers ([exn?
                   (lambda (failure)
                     (disconnect connection)
                     (raise failure))])
    ;; FULL makes a successful journal or projector commit the durability
    ;; boundary. Foreign keys protect cross-table source sequence references.
    (query-value connection "PRAGMA journal_mode = WAL")
    (query-exec connection "PRAGMA synchronous = FULL")
    (query-exec connection "PRAGMA foreign_keys = ON")
    (initialize-schema! connection)
    ;; Existing v7 stores also need the indexes: no data/schema migration
    ;; and no full event-journal scan on each hosted read.
    (query-exec
     connection
     "CREATE INDEX IF NOT EXISTS commerce_refund_journal_scope
      ON commerce_event_journal(subject_id, offer_id, event_kind)")
    (query-exec
     connection
     "CREATE INDEX IF NOT EXISTS commerce_outbox_source_kind
      ON commerce_issuance_outbox(source_journal_sequence, action)"))

  (define closed? (box #f))

  (define (check-open)
    (when (unbox closed?)
      (raise-commerce 'storage-closed "commerce storage is closed" (hash))))

  (define (accept payload event received-at)
    (check-open)
    (check-sqlite-integer
     'amount-minor-units (money-minor-units (payment-event-amount event)) event)
    (check-sqlite-integer 'occurred-at (payment-event-occurred-at event) event)
    (check-sqlite-integer 'received-at received-at event)
    (call-with-transaction
     connection
     (lambda ()
       (define existing
         (lookup-record connection
                        (payment-event-provider event)
                        (payment-event-event-id event)))
       (cond
         [existing
          (if (record-content=? existing payload event)
              (journal-acceptance 'replayed existing)
              (raise-commerce
               'event-conflict
               "provider event id was replayed with different content"
               (hash 'provider (payment-event-provider event)
                     'event-id (payment-event-event-id event)
                     'persisted-sequence
                     (journal-record-sequence existing))))]
         [else
          (query-exec
           connection
           #<<SQL
INSERT INTO commerce_event_journal
  (provider, event_id, raw_payload, payload_digest, event_kind, order_id,
   offer_id, subject_id, currency, amount_minor_units, occurred_at,
   received_at, paid_through)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
           (payment-event-provider event)
           (payment-event-event-id event)
           payload
           (payment-event-payload-digest event)
           (symbol->string (payment-event-kind event))
           (payment-event-order-id event)
           (payment-event-offer-id event)
           (payment-event-subject-id event)
           (money-currency (payment-event-amount event))
           (money-minor-units (payment-event-amount event))
           (payment-event-occurred-at event)
           received-at
           (sql-nullable (payment-event-paid-through event)))
          (journal-acceptance
           'accepted
           (lookup-record connection
                          (payment-event-provider event)
                          (payment-event-event-id event)))]))
     #:option 'immediate))

  (define (lookup-journal provider event-id)
    (check-open)
    (lookup-record connection provider event-id))

  (define (project-next processed-at)
    (check-open)
    (check-sqlite-integer 'processed-at processed-at)
    (call-with-transaction
     connection
     (lambda ()
       (define row (query-maybe-row connection select-next-unprojected-sql))
       (cond
         [(not row) #f]
         [else
          (define record (row->record row))
          (define sequence (journal-record-sequence record))
          (define event (journal-record-event record))
          (define previous
            (lookup-order connection
                          (payment-event-provider event)
                          (payment-event-order-id event)))
          (with-handlers
              ([exn:fail:commerce?
                (lambda (failure)
                  (if (eq? (exn:fail:commerce-code failure) 'order-conflict)
                      (begin
                        (query-exec
                         connection
                         #<<SQL
INSERT INTO commerce_projection_event
  (journal_sequence, status, failure_code, processed_at)
VALUES (?, 'blocked', 'order-conflict', ?)
SQL
                         sequence processed-at)
                        (projection-result
                         'blocked sequence previous '() 'order-conflict))
                      (raise failure)))])
            (define-values (next-order intents)
              (project-order-event previous event))
            (write-order! connection next-order sequence processed-at)
            (define outbox-items
              (for/list ([intent (in-list intents)])
                (write-outbox! connection intent sequence processed-at)))
            (query-exec
             connection
             #<<SQL
INSERT INTO commerce_projection_event
  (journal_sequence, status, failure_code, processed_at)
VALUES (?, 'projected', NULL, ?)
SQL
             sequence processed-at)
            (projection-result
             'projected sequence next-order outbox-items #f))]))
     #:option 'immediate))

  (define (lookup-projection provider order-id)
    (check-open)
    (lookup-order connection provider order-id))

  (define (lookup-work idempotency-key)
    (check-open)
    (lookup-outbox connection idempotency-key))

  ;; The claim transaction is the ownership boundary: one immediate
  ;; transaction selects the lowest due row and binds an exclusive lease to
  ;; the owner. Expired leases are reclaimable by anyone, including the
  ;; previous owner, and every reclaim is visible through attempts.
  (define (claim-work owner lease-seconds now)
    (check-sqlite-integer 'lease-seconds lease-seconds)
    (check-sqlite-integer 'lease-expires-at (+ now lease-seconds))
    (check-sqlite-integer 'now now)
    (call-with-transaction
     connection
     (lambda ()
       (define due
         (query-maybe-row connection select-due-work-sql now now))
       (and due
            (match-let ([(vector id idempotency-key) due])
              (query-exec
               connection
               #<<SQL
UPDATE commerce_issuance_outbox
SET status = 'processing', attempts = attempts + 1,
    lease_owner = ?, lease_expires_at = ?, updated_at = ?
WHERE id = ?
  AND ((status = 'pending' AND available_at <= ?) OR
       (status = 'processing' AND lease_expires_at <= ?))
SQL
               owner (+ now lease-seconds) now id now now)
              (lookup-outbox connection idempotency-key))))
     #:option 'immediate))

  ;; Completion appends the lineage root with revision zero, or exactly one
  ;; successor, and finishes the outbox row inside the same short transaction.
  ;; The caller must still hold the lease it claimed. Repeating a completion
  ;; that already landed reconciles to the recorded revision instead of
  ;; writing a second one.
(define (complete-work item issuer subject-type entitlement-id credential-id
                       policy-id policy-version payload-bytes issued-at
                       recorded-at signed-credential-bytes key-id
                       claim-token claim-expires-at)
    (check-sqlite-integer 'policy-version policy-version)
    (check-sqlite-integer 'recorded-at recorded-at)
    (when signed-credential-bytes
      (unless key-id
        (raise-commerce
         'invalid-issuance-record
         "recording a signed credential requires the signing key id"
         (hash 'idempotency-key (issuance-outbox-item-idempotency-key item)))))
    (when claim-token
      (unless (and signed-credential-bytes claim-expires-at)
        (raise-commerce
         'invalid-issuance-record
         "recording a claim requires signed credential bytes and an expiry"
         (hash 'idempotency-key (issuance-outbox-item-idempotency-key item)))))
    (define owner (issuance-outbox-item-lease-owner item))
    (define key (issuance-outbox-item-idempotency-key item))
    (define immutable-payload (bytes->immutable-bytes payload-bytes))
    (define actual-digest
      (bytes->hex-string (sha256-bytes immutable-payload)))
    (call-with-transaction
     connection
     (lambda ()
       (define row
         (query-maybe-row
          connection
          #<<SQL
SELECT id, action, offer_id, subject_id, status, lease_owner, lease_expires_at
FROM commerce_issuance_outbox
WHERE idempotency_key = ?
SQL
          key))
       (unless row
         (raise-commerce
          'unknown-issuance-work
          "issuance completion references unknown outbox work"
          (hash 'idempotency-key key)))
       (match-define
         (vector id action offer-id subject-id status lease-owner-row
                 lease-expires-at-row)
         row)
       (define recorded-revision
         (row->revision
          (query-maybe-row connection select-revision-by-outbox-sql id)))
       (cond
         [(string=? status "completed")
          (if (and recorded-revision
                   (string=? (entitlement-revision-payload-digest
                              recorded-revision)
                             actual-digest))
              (issuance-completion (lookup-outbox connection key)
                                   recorded-revision)
              (raise-commerce
               'entitlement-lineage-conflict
               "completed issuance work cannot record a different payload"
               (hash 'idempotency-key key 'outbox-id id)))]
         [else
          (unless (and owner
                       (string=? status "processing")
                       (equal? lease-owner-row owner)
                       lease-expires-at-row
                       (> lease-expires-at-row recorded-at))
            (raise-commerce
             'lease-not-held
             "issuance completion requires the active claim lease"
             (hash 'idempotency-key key 'outbox-id id)))
          (define action-symbol (string->symbol action))
          (define identity
            (query-maybe-row connection select-lineage-identity-sql
                             issuer subject-type subject-id offer-id))
          (define-values (next-revision previous-revision create-lineage?)
            (cond
              [identity
               (match-define (vector existing-id _) identity)
               (unless (string=? existing-id entitlement-id)
                 (raise-commerce
                  'entitlement-lineage-conflict
                  "the commercial identity is already bound to another entitlement"
                  (hash 'idempotency-key key
                        'offer-id offer-id
                        'subject-id subject-id
                        'lineage-entitlement-id existing-id
                        'requested-entitlement-id entitlement-id)))
               ;; Grant successors over an existing lineage are renewals;
               ;; the worker refuses second one-time grants before signing.
               (define latest
                 (row->revision
                  (query-maybe-row connection select-latest-revision-sql
                                   entitlement-id)))
               (unless latest
                 (raise-commerce
                  'entitlement-lineage-conflict
                  "entitlement lineage has no recorded revision"
                  (hash 'entitlement-id entitlement-id)))
               (values (add1 (entitlement-revision-revision latest))
                       (entitlement-revision-revision latest)
                       #f)]
              [(eq? action-symbol 'grant)
               (values 0 #f #t)]
              [else
               (raise-commerce
                'entitlement-lineage-required
                "withdrawal requires an existing entitlement lineage"
                (hash 'idempotency-key key
                      'offer-id offer-id
                      'subject-id subject-id))]))
          (when (= (query-value
                    connection
                    "SELECT EXISTS(SELECT 1 FROM commerce_entitlement_revision
WHERE credential_id = ?)"
                    credential-id)
                   1)
            (raise-commerce
             'entitlement-lineage-conflict
             "credential id is already bound to another entitlement revision"
             (hash 'idempotency-key key 'credential-id credential-id)))
          (when create-lineage?
            (query-exec
             connection
             #<<SQL
INSERT INTO commerce_entitlement_lineage
  (entitlement_id, issuer, subject_type, subject_id, credential_type,
   offer_id, created_at)
VALUES (?, ?, ?, ?, 'entitlement', ?, ?)
SQL
             entitlement-id issuer subject-type subject-id offer-id
             recorded-at))
          (query-exec
           connection
           #<<SQL
INSERT INTO commerce_entitlement_revision
  (entitlement_id, revision, previous_revision, credential_id,
   issuance_outbox_id, action, policy_id, policy_version, payload_bytes,
   payload_digest, issued_at, recorded_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
           entitlement-id next-revision (sql-nullable previous-revision)
           credential-id id action policy-id policy-version immutable-payload
           actual-digest issued-at recorded-at)
          (query-exec
           connection
           #<<SQL
UPDATE commerce_issuance_outbox
SET status = 'completed', lease_owner = NULL, lease_expires_at = NULL,
    completed_at = ?, updated_at = ?
WHERE id = ?
SQL
           recorded-at recorded-at id)
          ;; The signed envelope and its one-time claim land in the same
          ;; transaction as the revision, so a completed issuance always has
          ;; its delivery evidence or the caller chose to record none.
          (when signed-credential-bytes
            (query-exec
             connection
             #<<SQL
INSERT INTO commerce_issued_credential
  (issuance_outbox_id, entitlement_id, revision, credential_id, key_id,
   envelope_bytes, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
SQL
             id entitlement-id next-revision credential-id key-id
             (bytes->immutable-bytes signed-credential-bytes) recorded-at)
            (when claim-token
              (query-exec
               connection
               #<<SQL
INSERT INTO commerce_claim
  (claim_token_digest, issued_credential_id, status, notified_at,
   claimed_at, expires_at, created_at, updated_at)
VALUES (?, (SELECT id FROM commerce_issued_credential
WHERE issuance_outbox_id = ?), 'ready', NULL, NULL, ?, ?, ?)
SQL
               (bytes->hex-string
                (sha256-bytes (string->bytes/utf-8 claim-token)))
               id claim-expires-at recorded-at recorded-at)))
          (issuance-completion
           (lookup-outbox connection key)
           (lookup-revision connection entitlement-id next-revision))]))
     #:option 'immediate))

  ;; A transient failure releases the claimed row for bounded retry without
  ;; touching attempts, which the claim already incremented. Only the lease
  ;; owner may release, and completed work can never be released.
  (define (release-work item error-code retry-at)
    (check-sqlite-integer 'retry-at retry-at)
    (define owner (issuance-outbox-item-lease-owner item))
    (define key (issuance-outbox-item-idempotency-key item))
    (call-with-transaction
     connection
     (lambda ()
       (define row
         (query-maybe-row
          connection
          "SELECT id, status, lease_owner FROM commerce_issuance_outbox WHERE idempotency_key = ?"
          key))
       (unless row
         (raise-commerce
          'unknown-issuance-work
          "issuance release references unknown outbox work"
          (hash 'idempotency-key key)))
       (match-define (vector id status lease-owner-row) row)
       (unless (and owner
                    (string=? status "processing")
                    (equal? lease-owner-row owner))
         (raise-commerce
          'lease-not-held
          "issuance release requires the active claim lease"
          (hash 'idempotency-key key 'outbox-id id)))
       (query-exec
        connection
        #<<SQL
UPDATE commerce_issuance_outbox
SET status = 'pending', available_at = ?, lease_owner = NULL,
    lease_expires_at = NULL, last_error_code = ?, updated_at = ?
WHERE id = ?
SQL
        retry-at (symbol->string error-code) retry-at id)
       (lookup-outbox connection key))
      #:option 'immediate))

  ;; Fulfilling a claim is one short transaction: verify the token digest,
  ;; verify the state and window, mark claimed, and return the exact signed
  ;; envelope bytes. Fulfillment never touches lineage evidence.
  (define (claim-credential token now)
    (check-sqlite-integer 'now now)
    (define digest
      (bytes->hex-string (sha256-bytes (string->bytes/utf-8 token))))
    (call-with-transaction
     connection
     (lambda ()
       (define row
         (query-maybe-row
          connection
          #<<SQL
SELECT c.id, c.status, c.expires_at, i.id, i.issuance_outbox_id,
       i.entitlement_id, i.revision, i.credential_id, i.key_id,
       i.envelope_bytes, i.created_at
FROM commerce_claim AS c
JOIN commerce_issued_credential AS i
  ON i.id = c.issued_credential_id
WHERE c.claim_token_digest = ?
SQL
          digest))
       (cond
         [(not row)
          (raise-commerce
           'claim-not-found
           "claim token does not match any recorded claim"
           (hash))]
         [else
          (match-define
            (vector claim-id status expires-at credential-record-id
                    outbox-id entitlement-id revision credential-id
                    envelope-key-id envelope-bytes created-at)
            row)
          (cond
            [(string=? status "claimed")
             (raise-commerce
              'claim-already-claimed
              "claim token was already fulfilled"
              (hash 'claim-id claim-id))]
            [(or (string=? status "expired") (<= expires-at now))
             (raise-commerce
              'claim-expired
              "claim token is outside its fulfillment window"
              (hash 'claim-id claim-id 'expires-at expires-at 'now now))]
            [else
             (query-exec
              connection
              #<<SQL
UPDATE commerce_claim
SET status = 'claimed', claimed_at = ?, updated_at = ?
WHERE id = ? AND status = 'ready'
SQL
              now now claim-id)
             (claim-fulfillment
              claim-id
              (issued-credential-record
               credential-record-id outbox-id entitlement-id revision
               credential-id envelope-key-id
               (bytes->immutable-bytes envelope-bytes)
               created-at)
              now)])]))
     #:option 'immediate))

  ;; Records that the claim token was handed to a delivery transport. The
  ;; first timestamp wins so notification retries stay idempotent.
  (define (mark-claim-notified token now)
    (check-sqlite-integer 'now now)
    (define digest
      (bytes->hex-string (sha256-bytes (string->bytes/utf-8 token))))
    (call-with-transaction
     connection
     (lambda ()
       (define row
         (query-maybe-row
          connection
          "SELECT id, status FROM commerce_claim WHERE claim_token_digest = ?"
          digest))
       (cond
         [(not row)
          (raise-commerce
           'claim-not-found
           "claim token does not match any recorded claim"
           (hash))]
         [else
          (match-define (vector claim-id status) row)
          (when (string=? status "claimed")
            (raise-commerce
             'claim-already-claimed
             "claim token was already fulfilled"
             (hash 'claim-id claim-id)))
          (query-exec
           connection
           #<<SQL
UPDATE commerce_claim
SET notified_at = COALESCE(notified_at, ?), updated_at = ?
WHERE id = ?
SQL
           now now claim-id)]))
     #:option 'immediate))

  ;; Operator scan: the outbox rows in stable id order, optionally filtered
  ;; by status. Enumeration is read-only and exposes workflow state only.
  (define (outbox-scan status)
    (define rows
      (query-rows connection select-outbox-scan-sql))
    (for/list ([row (in-list rows)]
               #:when (or (not status)
                          (string=? (vector-ref row 9)
                                    (symbol->string status))))
      (row->outbox row)))

  (define (order-journal provider order-id)
    (for/list ([row (in-list
                     (query-rows connection select-order-journal-sql
                                 provider order-id))])
      (row->record row)))

  (define (order-outbox provider order-id)
    (for/list ([row (in-list
                     (query-rows connection select-order-outbox-sql
                                 provider order-id))])
      (row->outbox row)))

  (define (issued-credential-ref issuance-outbox-id)
    (check-open)
    (check-sqlite-integer 'issuance-outbox-id issuance-outbox-id)
    (lookup-issued-credential connection issuance-outbox-id))

  ;; Redrive makes one pending row due immediately without touching its
  ;; attempts counter. In-flight and completed work is never rewound.
  (define (redrive-work idempotency-key now)
    (check-sqlite-integer 'now now)
    (call-with-transaction
     connection
     (lambda ()
       (define row
         (query-maybe-row
          connection
          "SELECT id, status FROM commerce_issuance_outbox WHERE idempotency_key = ?"
          idempotency-key))
       (cond
         [(not row)
          (raise-commerce
           'unknown-issuance-work
           "issuance redrive references unknown outbox work"
           (hash 'idempotency-key idempotency-key))]
         [else
          (match-define (vector id status) row)
          (cond
            [(string=? status "processing")
             (raise-commerce
              'lease-not-held
              "issuance redrive cannot rewind in-flight work"
              (hash 'idempotency-key idempotency-key 'outbox-id id))]
            [(string=? status "completed")
             (raise-commerce
              'work-already-completed
              "issuance redrive cannot rewind completed work"
              (hash 'idempotency-key idempotency-key 'outbox-id id))]
            [else
             (query-exec
              connection
              #<<SQL
UPDATE commerce_issuance_outbox
SET available_at = ?, updated_at = ?
WHERE id = ? AND status = 'pending'
SQL
              now now id)
             (lookup-outbox connection idempotency-key)])]))
     #:option 'immediate))

  ;; One read-only aggregate answers readiness and stuck-work questions;
  ;; every count comes from the same snapshot moment (the query instant).
  (define (readiness-snapshot now)
    (check-open)
    (check-sqlite-integer 'now now)
    (match-define
      (vector journal-total journal-unprojected projection-blocked
              work-pending work-processing work-lease-expired
              work-oldest-pending-at claim-ready claim-claimed
              claim-window-passed)
      (query-row connection select-readiness-sql now))
    (readiness
     schema-version journal-total journal-unprojected projection-blocked
     work-pending work-processing (nullable work-lease-expired)
     (nullable work-oldest-pending-at) claim-ready claim-claimed
     claim-window-passed))

  ;; Retention transitions expired-window claims to their terminal state.
  ;; Status transitions are the only mutation claims allow; deletion of
  ;; journal, lineage, or claim rows stays a versioned, audited schema
  ;; operation outside this boundary.
  (define (retire-expired-claims now)
    (check-open)
    (check-sqlite-integer 'now now)
    (call-with-transaction
     connection
     (lambda ()
       (query-exec
        connection
        #<<SQL
UPDATE commerce_claim
SET status = 'expired', updated_at = ?
WHERE status = 'ready' AND expires_at <= ?
SQL
        now now)
       (query-value connection "SELECT changes()"))
      #:option 'immediate))

  ;; Checkout bindings are the durable server-side expectation created with
  ;; a checkout: one provider product, stable Offer, stable subject, and the
  ;; exact expected money, keyed by the opaque merchant external reference.
  (define (create-checkout-binding! binding created-at)
    (check-open)
    (check-sqlite-integer 'created-at created-at)
    (call-with-transaction
     connection
     (lambda ()
       (query-exec
        connection
        #<<SQL
INSERT INTO commerce_checkout_binding
  (merchant_external_id, provider, product_id, offer_id, subject_id,
   currency, amount_minor_units, currency_exponent, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
        (checkout-binding-merchant-external-id binding)
        (checkout-binding-provider binding)
        (checkout-binding-product-id binding)
        (checkout-binding-offer-id binding)
        (checkout-binding-subject-id binding)
        (checkout-binding-currency binding)
        (checkout-binding-amount-minor-units binding)
        (checkout-binding-currency-exponent binding)
        created-at)
       binding)
      #:option 'immediate))

  (define (checkout-binding-ref merchant-external-id)
    (check-open)
    (define row
      (query-maybe-row
       connection
       #<<SQL
SELECT merchant_external_id, provider, product_id, offer_id, subject_id,
       currency, amount_minor_units, currency_exponent, created_at
FROM commerce_checkout_binding
WHERE merchant_external_id = ?
SQL
       merchant-external-id))
    (and row
         (match-let ([(vector id provider product-id offer-id subject-id
                            currency amount exponent _created-at)
                      row])
           (checkout-binding
            id provider product-id offer-id subject-id currency amount
            exponent))))

  ;; Operator actions are only real if they leave append-only evidence.
  ;; The audit record names the action, the accountable operator, a free
  ;; reason, and one subject identifier.
  (define (append-audit! action operator reason subject created-at)
    (check-open)
    (check-sqlite-integer 'created-at created-at)
    (call-with-transaction
     connection
     (lambda ()
       (query-exec
        connection
        "INSERT INTO commerce_operator_audit
  (action, operator, reason, subject, created_at) VALUES (?, ?, ?, ?, ?)"
        action operator reason subject created-at)
       (query-value connection "SELECT last_insert_rowid()"))
      #:option 'immediate))

  (define (audit-scan action)
    (check-open)
    (for/list ([row
                (in-list
                 (if action
                     (query-rows
                      connection
                      "SELECT id, action, operator, reason, subject, created_at
FROM commerce_operator_audit WHERE action = ? ORDER BY id"
                      action)
                     (query-rows
                      connection
                      "SELECT id, action, operator, reason, subject, created_at
FROM commerce_operator_audit ORDER BY id")))])
      (match-define (vector id audit-action audit-operator audit-reason
                            audit-subject created-at)
        row)
      (operator-audit-record id audit-action audit-operator audit-reason
                             audit-subject created-at)))

  ;; Reissue gives a customer whose claim window passed a fresh one-time
  ;; claim for the SAME issued credential. It never creates a second
  ;; credential or lineage revision, and it always appends audit evidence.
  (define (reissue-claim! claim-id new-token expires-at operator reason now)
    (check-open)
    (check-sqlite-integer 'claim-id claim-id)
    (check-sqlite-integer 'expires-at expires-at)
    (check-sqlite-integer 'now now)
    (define digest
      (bytes->hex-string (sha256-bytes (string->bytes/utf-8 new-token))))
    (call-with-transaction
     connection
     (lambda ()
       (define row
         (query-maybe-row
          connection
          #<<SQL
SELECT c.issued_credential_id, i.credential_id
FROM commerce_claim AS c
JOIN commerce_issued_credential AS i
  ON i.id = c.issued_credential_id
WHERE c.id = ?
SQL
          claim-id))
       (unless row
         (raise-commerce
          'claim-not-found
          "claim reissue references an unknown claim"
          (hash 'claim-id claim-id)))
       (match-define (vector credential-record-id credential-id) row)
       (query-exec
        connection
        #<<SQL
INSERT INTO commerce_claim
  (claim_token_digest, issued_credential_id, status, notified_at,
   claimed_at, expires_at, created_at, updated_at)
VALUES (?, ?, 'ready', NULL, NULL, ?, ?, ?)
SQL
        digest credential-record-id expires-at now now)
       (define new-id
         (query-value connection "SELECT last_insert_rowid()"))
       (query-exec
        connection
        "INSERT INTO commerce_operator_audit
  (action, operator, reason, subject, created_at)
VALUES ('reissue-claim', ?, ?, ?, ?)"
        operator reason
        (format "claim ~a -> claim ~a credential ~a"
                claim-id new-id credential-id)
        now)
       new-id)
      #:option 'immediate))

  (define (claim-record-ref claim-id)
    (check-open)
    (check-sqlite-integer 'claim-id claim-id)
    (define row
      (query-maybe-row
       connection
       #<<SQL
SELECT id, claim_token_digest, issued_credential_id, status, notified_at,
       claimed_at, expires_at, created_at, updated_at
FROM commerce_claim WHERE id = ?
SQL
       claim-id))
    (and row
         (match row
           [(vector id digest issued-id status notified-at claimed-at
                    expires-at created-at updated-at)
            (claim-record
             id digest issued-id (string->symbol status)
             (nullable notified-at)
             (nullable claimed-at) expires-at created-at updated-at)])))

  (define (entitlement-ref entitlement-id)
    (check-open)
    (lookup-lineage connection entitlement-id))

  (define (lineage-ref issuer subject-type subject-id offer-id)
    (check-open)
    (define identity
      (query-maybe-row connection select-lineage-identity-sql
                       issuer subject-type subject-id offer-id))
    (and identity
         (lookup-lineage connection (vector-ref identity 0))))

  (define (revision-ref entitlement-id revision)
    (check-open)
    (check-sqlite-integer 'revision revision)
    (lookup-revision connection entitlement-id revision))

  (define (latest-revision entitlement-id)
    (check-open)
    (row->revision
     (query-maybe-row connection select-latest-revision-sql entitlement-id)))

  (define (unresolved-refund subject-id offer-id)
    (check-open)
    (not (zero? (query-value connection select-unresolved-refund-sql
                             subject-id offer-id))))

  (define (close)
    (unless (unbox closed?)
      (disconnect connection)
      (set-box! closed? #t)))

  (commerce-storage
   accept lookup-journal project-next lookup-projection lookup-work
   claim-work complete-work release-work
   entitlement-ref lineage-ref revision-ref latest-revision
   claim-credential mark-claim-notified
   outbox-scan order-journal order-outbox issued-credential-ref redrive-work
   readiness-snapshot retire-expired-claims
   create-checkout-binding! checkout-binding-ref
   append-audit! audit-scan reissue-claim! claim-record-ref
   unresolved-refund close))
