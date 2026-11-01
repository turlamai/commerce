#lang racket/base

(provide
 (struct-out commerce-storage)
 (struct-out projection-result)
 (struct-out issuance-outbox-item)
 (struct-out entitlement-lineage)
 (struct-out entitlement-revision)
 (struct-out issuance-completion)
 (struct-out issued-credential-record)
 (struct-out claim-fulfillment)
 (struct-out readiness)
 (struct-out checkout-binding)
 (struct-out operator-audit-record)
 (struct-out claim-record))

;; One opaque service-storage handle owns journal, projection, outbox,
;; issuance, and claim operations so the SQLite backend can enforce their
;; transaction boundaries.
(struct commerce-storage
  (journal-accept journal-lookup project-next order-lookup outbox-lookup
                  issuance-claim issuance-complete issuance-release
                  entitlement-lookup lineage-lookup revision-lookup
                  latest-revision-lookup claim-lookup claim-notified
                  outbox-scan order-journal order-outbox
                  issued-credential-lookup redrive readiness
                  retire-expired-claims
                  checkout-binding-create checkout-binding-lookup
                  audit-append audit-scan reissue claim-record-lookup
                  unresolved-refund close)
  #:transparent)

;; disposition is 'projected or 'blocked. No pending journal row is represented
;; by #f, so callers cannot confuse idle work with a committed transition.
(struct projection-result
  (disposition journal-sequence order outbox failure-code)
  #:transparent)

;; Workflow fields are present now so emitted rows have a stable lease shape;
;; this slice only inserts pending work and does not expose worker mutations.
(struct issuance-outbox-item
  (id idempotency-key source-sequence action provider order-id offer-id
      subject-id occurred-at status attempts available-at lease-owner
      lease-expires-at last-error-code created-at updated-at completed-at)
  #:transparent)

;; The stable entitlement identity. credential_type is a schema constant
;; ('entitlement) because Commerce only maps Offers to Permit entitlement
;; credentials.
(struct entitlement-lineage
  (entitlement-id issuer subject-type subject-id offer-id created-at)
  #:transparent)

;; One append-only revision of unsigned Permit evidence. payload-bytes are the
;; exact unsigned snapshot bytes; they are never signed credential bytes.
(struct entitlement-revision
  (entitlement-id revision previous-revision credential-id issuance-outbox-id
                  action policy-id policy-version payload-bytes payload-digest
                  issued-at recorded-at)
  #:transparent)

;; Completion returns the finished work together with the revision it appended,
;; so a retry after an ambiguous crash reconciles instead of duplicating.
(struct issuance-completion (outbox revision) #:transparent)

;; The durable signed-credential audit record. envelope-bytes are the exact
;; serialized Permit envelope (key id, payload, signature) as delivered.
(struct issued-credential-record
  (id issuance-outbox-id entitlement-id revision credential-id key-id
      envelope-bytes created-at)
  #:transparent)

;; One-time claim fulfillment: the claim row id, the credential it unlocks,
;; and the fulfillment time.
(struct claim-fulfillment (claim-id credential claimed-at) #:transparent)

;; One read-only readiness snapshot. Counts are self-explanatory; the two
;; nullable fields are absent when their rows do not exist. stale-lease
;; counts processing rows whose lease has already expired; claim
;; window-passed counts ready claims nobody fulfilled in time.
(struct readiness
  (schema-version journal-total journal-unprojected projection-blocked
                  work-pending work-processing work-stale-lease
                  work-oldest-pending-at claim-ready claim-claimed
                  claim-window-passed)
  #:transparent)

;; The durable server-side checkout expectation. The merchant external id
;; is the opaque correlation reference created with the checkout; it maps
;; to one provider product, stable Offer, stable subject, and exact money.
(struct checkout-binding
  (merchant-external-id provider product-id offer-id subject-id currency
                        amount-minor-units currency-exponent)
  #:transparent)

;; Append-only operator-action evidence: what was done, by whom, why, and
;; on which subject identifier.
(struct operator-audit-record
  (id action operator reason subject created-at)
  #:transparent)

;; The durable one-time claim row behind a fulfillment.
(struct claim-record
  (id claim-token-digest issued-credential-id status notified-at claimed-at
      expires-at created-at updated-at)
  #:transparent)
