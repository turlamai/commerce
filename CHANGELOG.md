# Changelog

All notable changes to Commerce are documented here.

## Unreleased

### Added

- Add an internal Alipay checkout coordinator with operator-reviewed Offer
  and provider admission, durable request claims and immutable order binding.
  Retries reuse the same order; conflicting account or merchant settings fail
  closed. This adds no public endpoint or authorization to accept money.

- Add `raco commerce doctor <database>`: a genuinely read-only operational
  probe with a SQLite read-only connection, schema-version check, journal and
  work counts, claim state and typed health warnings in JSON. It exits 1 for
  unhealthy or incompatible databases and never bootstraps, migrates or
  creates indexes while inspecting the service.

### Fixed

- Make the README quick start runnable: clone the repository, install it as a
  linked package, then run `examples/first-purchase.rkt`. Installing by URL
  and immediately running a repository-relative example could not work
  outside a checkout. Apply the same `--link "$PWD"` fix to both development
  install snippets.

- Reconcile the documented SQLite schema with the code: the READMEs said v7
  and v4 while `storage/sqlite.rkt` defines v8. Add a documentation test that
  reads `schema-version` and requires both READMEs to state it, so the next
  migration cannot silently leave the prose behind.

- Give the Scribble manual a `@defmodule[commerce]` anchor and convert the
  Money and Offer value sections from `@verbatim` signatures to indexed
  `@defproc` entries. Larger reference coverage remains tracked separately.

- State the verified-evidence boundary accurately in `docs/security.md`:
  re-verification runs when the issuance worker is assembled with
  `#:evidence-verifier`, whose default is `#f` for fixture-only harnesses.
  Production assemblies must supply it.

### Security

- Keep the hosted-service key registry opaque to Racket diagnostic printing.
  A transparent registry struct previously serialized file-backed HMAC secret
  bytes in `~v`, `~s` or `~a` debugging/logging. Add a regression covering
  all three formats while preserving explicit trusted key resolution (#21).

- Add the Pancake signed refund flow (issue #40): the webhook edge now
  dispatches on the verified event type and journals `refund.succeeded`
  webhooks as `payment-refunded` rows with the same signature-evidence
  envelope as payments — full-refund invariant enforced at the edge
  (`refundedAmount == originalChargedAmount == binding amount`; partial
  refunds and `refund.failed` refuse durably without a journal row).
  The issuer re-verifies Pancake refund rows offline — signature from
  journaled evidence, event-type fence, binding subject/offer, and both
  refund amounts against the journal row and binding — replacing the
  previous `evidence-kind-unsupported` fail-closed gap. Commerce never
  initiates refunds; only signed outcomes are recorded.

- Close the remaining verified-evidence forgery gaps in the issuer role
  (issue #38): grants and withdrawals now fence the claimed outbox
  subject against the journaled event, re-derive offer/subject from the
  append-only checkout binding (`evidence-binding-missing` /
  `evidence-binding-mismatch`), and withdrawal intents re-verify the
  journaled signed full-refund query proof — request id recovered from
  the `refund:<id>` event id, order/amount/settlement time cross-checked
  against the binding and the signed bytes — closing the forged-refund
  denial-of-service window. A compromised edge can no longer redirect a
  genuine payment or refund to another subject via forged journal rows,
  retargeted outbox rows, or a rewritten order projection. Creating new
  checkouts for arbitrary subjects remains the product identity
  boundary's responsibility (issue #21), not Commerce's.

- Enforce the ADR-0020 verified-evidence boundary in the issuer role
  (issue #10): journal rows gain a `signature_evidence` column (schema
  v8), the Pancake edge journals the exact signature header it
  authenticated, and a new `commerce/evidence.rkt` verifier re-verifies
  stored provider signatures offline with issuer-held public keys, binds
  the claimed outbox Offer to the journaled evidence, and anchors the
  amount to the pinned catalog price before any grant is signed. Forged
  journal rows, tampered amounts/statuses, retargeted outbox intents,
  unknown or deleted Offers, missing evidence, and unconfigured verifier
  keys all fail closed with typed refusals and no lineage or revision
  written. Withdrawals intentionally skip payment re-verification: a
  forged refund can deny service but cannot mint rights. The
  offer-to-subject binding remains edge-written and is recorded as the
  residual milestone.

### Fixed

- Use timezone-independent Gregorian UTC+08:00 conversion for Alipay gateway
  timestamps and authenticated payment/refund evidence. Host-local civil time
  previously risked shifting signed event occurrence and breaking durable replay
  identity outside UTC CI. Add leap-day, invalid-date and fixed-epoch tests (#23).


- Import `storage-close` explicitly in the hosted proof HTTP example and
  its regression suite. The SQLite backend module does not re-export this
  lifecycle operation; the missing binding previously prevented package
  setup and every CI leg from reaching the hosted admission tests. No
  authentication, signing, request scope or payment behavior changes.

- Correct outdated first-product roadmap and bilingual README claims: issue #1
  and PR #2 are closed/merged, while merchant approval, production signer
  authorization and live evidence remain open gates. Add a root confidential
  security policy, PR/agent handoff template, auditable release checklist and
  documentation links/tests; update a stale organization URL.

- Load the issuer's Permit trust store through Permit's strict JSON reader,
  rather than a generic JSON parse that could discard duplicate security-
  critical fields. Add rejection and valid-file regression tests. Reject
  `COMMERCE_ENVIRONMENT=production` with a combined HTTP/signing role before
  secret file or database access, with role-policy tests. The bundled demo
  entitlement catalog also refuses all production issuance until a real,
  reviewed policy replaces the fixture, with explicit negative tests.

- Keep the in-memory issuance worker and the claim-token-bearing issuance
  result opaque to Racket diagnostic printing; test both display
  representations so accidental logging cannot serialize private fields.
  Process-level key isolation remains a separate production security gate
  (issue #10).

- Keep operator CLI failures machine-readable as JSON (`invalid-arguments`
  or `database-not-found`, exit 1), and refuse to silently create a new
  database from an operator command, with regression tests; update outdated
  operations and README schema/CLI descriptions to match the current v7 store.

- Render every issued RFC 3339 timestamp in true UTC regardless of the
  host time zone. `seconds->date` is local wall clock (the positional
  boolean is leap-second precision, not a UTC flag), so on a UTC+8 host
  the default clock's `issued_at` and subscription paid-through windows
  came out eight hours early while CI, running in UTC, could not see it.
  The conversion now uses a zone-free civil calendar derivation with UTC
  anchor tests; the subscription tests assert the production spelling
  instead of a test-local copy that agreed with the old bug.

### Added

- Add an operator-only, explicitly provisioned SQLite full-refund operation
  ledger for Alipay (#23). Record a unique order/request/approval binding,
  durably mark the first money-moving dispatch `unknown` before calling a
  trusted transport, never resend unknown outcomes, and record `confirmed`
  only after signed full-refund query evidence is journaled. Includes synthetic
  crash/timeout/replay/authorization tests; no live merchant or refund action.


- Add ADR-0019 strict, operator-owned provider admission manifests and a
  pre-binding Alipay checkout guard. A checkout is refused unless an approved,
  unexpired merchant/environment/Offer capability with exact price, currency,
  payment method and contract paths matches. The shipped template is invalid
  by default; synthetic fixture acceptance is **not** merchant approval (#5).


- Add bounded Alipay one-time **full refund** RSA2 request and refund-query
  proof primitives, requiring exact original CNY amount, stable refund ID,
  authenticated response and explicit `REFUND_SUCCESS`. Reject partial
  refunds instead of misrepresenting them in the binary refunded model;
  no automatic journal/Permit withdrawal from unconfirmed refunds.


- Start an optional Alipay Vibe Pay Basic Collection Racket adapter slice:
  RSA2-signed notification canonicalization and verification, CNY
  minor-unit conversion, matching merchant/Offer/subject checkout binding
  plus independently authenticated order-query evidence, and negative
  synthetic RSA fixtures. Document that checkout creation, production HTTP,
  active query, refunds and merchant admission are **not** implemented.


- Add role-separated Commerce service startup: the HTTP edge no longer needs
  the Permit signing key, and the issuer/projector runs without an HTTP
  listener. Ship separate systemd unit templates and document the residual
  shared-writable-DB trust boundary in ADR-0020 (partial issue #10). Retain
  combined mode for local demos only.

- Pin the production-tested Permit dependency to source commit `ed32d0eec463665e470657e54d222a1b98148a1e` in
  cross-platform CI and Docker builds, while retaining a latest-main
  compatibility lane. Pin CI action revisions, exercise Docker builds in CI,
  explicitly copy local Permit sources (do not leave dangling linked packages),
  and require a verified base-image digest for production releases.

- Add the provider admission gate (ADR-0019): no adapter presents a
  live checkout until an admission record is complete — approved
  account scope, capability matrix (method × currency × transaction
  type × amount bounds, every cell unknown without approved evidence),
  verified checkout-creation and order-read contract paths, separately
  staged costs, and typed refusal of offers outside the matrix.
  Pancake and ZPAY are recorded as not admitted; fixture conformance is
  explicitly not eligibility.
- Add scenario-level recovery journeys (`commerce-test/recovery-test.rkt`)
  proving the four operator recovery routes at the fixture boundary: a
  delayed webhook, a duplicate callback, a lost browser return, and a
  failed credential import. Each journey asserts the no-second-charge
  invariants — one journal event, one outbox row, one credential, one
  lineage revision — and the runbook names each route in the same words.
- Add the deployment assembly: `examples/service.rkt` (one process
  running the HTTP edge, projector, and issuer worker over one SQLite
  store, environment-configured with file-injected secrets), a `GET
  /readyz` readiness endpoint rendering the health snapshot with typed
  warnings (503 when an operator is needed), and `deploy/` runners — a
  hardened systemd unit and a Docker image with a `/data` volume.
  Termination is crash-safe by design; TLS, rate limiting, and log
  shipping stay external (ADR-0018).
- Add operator audit, claim reissue, the claim portal, and provider
  reconciliation on SQLite schema v7: an append-only audit table
  recording action/operator/reason/subject for every manual action; a
  rebuilt claim table that lets reissue append a fresh claim for the
  same issued credential with audited fresh tokens; a `/claims` HTTP
  endpoint fulfilling one-time tokens with typed 404/409/410 refusals;
  and `commerce/reconcile` comparing signed provider order-fact reads
  with projections into typed differences without ever mutating durable
  state. v1-v6 migrate in place.
- Add duration-based updates windows to the Permit policy model: a
  constraints policy states the window either as a fixed instant or as
  `#:updates-through-duration-days`, derived at issuance from the order's
  paid-at evidence (mutually exclusive by validation). Replays converge
  on the same bytes; withdrawal/renewal successors inherit the sold-with
  window and only the use window is rewritten.
  `examples/gptp-studio-updates-window.rkt` is the worked journey for the
  family's first paid product: a perpetual Pro edition whose updates
  window is each purchase's own anniversary.
- Add `commerce/server`, the HTTP webhook edge, and SQLite schema v6:
  the edge authenticates the exact request bytes, resolves the
  append-only durable checkout binding by order id, actively verifies
  the one-time order, journals idempotently, and acknowledges with a
  total status mapping (401/404/409/422/503) — with no issuance,
  signing, or delivery in the request path. v1-v5 databases migrate in
  place.
- Add subscription semantics on SQLite schema v5: the canonical payment
  event carries the provider-reported paid-through window; the projection
  advances to that window and emits one idempotently keyed renewal intent
  per new window (late events never shrink it); the Permit mapping gains
  the renew action and an explicit use-expiry so renewals lapse at the
  paid window and subscription cancellations expire at period end; the
  worker distinguishes renewals from second one-time purchases by the
  order projection and still refuses second one-time grants before
  signing. v1-v4 databases migrate in place.
- Add operational evidence tooling: `snapshot-commerce-database!` writes a
  consistent SQLite copy via VACUUM INTO while the service runs,
  `verify-commerce-backup` rehearses restores by checking integrity,
  database identity, schema version, and journal counts against the
  original, and `storage-retire-expired-claims!` transitions
  window-passed claims to their terminal expired state without deleting
  any durable evidence.
- Add `storage-readiness`, a single read-only snapshot of journal,
  projection, issuance-lease, and claim state, and `commerce/health`,
  which classifies it into typed stuck-work warnings
  (`projection-blocked`, `issuance-lease-expired`, `claim-window-passed`)
  with optional operator-visible logging. The future HTTP edge renders
  this value; nothing mutates.
- Add `raco commerce`, the operator CLI wrapping `commerce/operator`:
  `find` enumerates outbox work by status, `explain` prints a redacted
  JSON order story, and `redrive` makes one pending row due with typed
  nonzero-refusal exits.
- Add `commerce/log`, the single structured logging path:
  redacted-by-construction events with a closed whitelist of correlation
  keys and scalar field values, instrumenting journal acceptance and
  conflict, projection and blocking, lease claim/complete/release,
  redrive, and claim fulfillment or refusal. Raw bytes, tokens, and
  unlisted keys are rejected before emission; transport formatting stays
  a deployment concern.
- Add the runnable end-to-end journey (`examples/full-journey.rkt`) over
  the real protocol boundaries — authenticated Pancake webhook, actively
  verified one-time order, durable journal/projection, deterministic
  Ed25519 issuance, one-time claim fulfillment, refund withdrawal, and the
  operator explanation — plus the operator runbook
  (`docs/runbook.md`) covering paid-but-inactive, replay/redrive, refund
  reality, claim states, and the live sandbox drill.
- Add the `commerce/operator` replay surface: redacted order explanations
  (projection, canonical event snapshots, outbox work, issued-credential
  evidence), status-filtered outbox enumeration, and bounded redrive that
  makes pending work due without touching attempts, rewinding in-flight or
  completed work, or editing projection rows.
- Add one-time claim delivery on SQLite schema v4: an append-only
  issued-credential record retaining the exact signed envelope bytes, a
  claim table storing only the SHA-256 digest of a random one-time token,
  ready/claimed/expired fulfillment states with idempotent notification
  marks, and typed claim fulfillment that returns the signed bytes without
  ever advancing a lineage revision. The worker's completion transaction
  records the credential and its claim atomically; v3 databases migrate in
  place. No HTTP listener, transport, or portal is included.
- Add the explicit `commerce/issuer` worker: deterministic entitlement and
  credential id derivation, version-pinned snapshot preparation, and
  deterministic Ed25519 signing of the exact recorded bytes outside the claim
  transaction. Deterministic dead ends are refused and released with typed
  codes before any signing; Permit signing failures release as
  `permit-issue-failed` with bounded backoff and complete after operator
  repair; a lost lease between claim and completion reports `lease-lost` and
  writes nothing. No signed credential bytes, delivery tokens, or HTTP
  listeners are included.
- Add an owner-safe issuance-outbox lease state machine: exclusive claim in
  one immediate transaction with observable attempts, expired-lease reclaim,
  owner-checked completion, and typed release with a bounded retry time.
  Completion appends the lineage root plus revision zero, or exactly one
  successor, in the same transaction that completes the outbox row, binds the
  pinned policy id/version and deterministic lineage ids, computes the payload
  digest server-side, and reconciles repeated completion to the recorded
  revision. Lineage and revision readers expose durable audit state. No
  signing, signed-credential persistence, delivery, or HTTP listener is
  included.
- Add SQLite schema v3 with immutable entitlement roots and contiguous Permit
  revision evidence. Fresh, v1, and v2 databases migrate atomically without
  rewriting journal/outbox evidence; no lease worker, signer, signed credential,
  or delivery behavior is implied.
- Add validated, version-pinned Offer-to-Permit policy mapping for one-time
  grants and issuance-expiring withdrawal successors. Active and retained
  retired Offers resolve deterministically; unknown, deleted, mismatched, and
  invalid policy or lineage inputs fail with typed Commerce errors before
  signing.
- Add SQLite schema v2 with replayable order projection, durable projection
  outcomes, and transactional issuance-outbox insertion. Schema v1 migrates in
  place, deterministic conflicts become durable blocked work, and injected
  write failures prove order/outbox/marker rollback as one unit.
- Add signed Pancake merchant GraphQL reads and active one-time-order
  verification. A completed order must match its webhook, environment, store,
  checkout binding, product, succeeded payment, currency, and exact minor-unit
  amount before `commerce/pancake` constructs a canonical payment event.
- Add `commerce/pancake`, an explicit exact-byte RSA-SHA256 webhook verifier
  with test/production key isolation, asymmetric replay windows, mode binding,
  duplicate-field rejection, redacted typed failures, and independently
  checked protocol fixtures.
- Add a backend-neutral durable journal contract and a SQLite v1 backend that
  stores exact authenticated bytes plus canonical event snapshots, verifies
  payload digests, distinguishes accepted/exact/conflicting replay, and blocks
  row mutation or deletion at the database layer.
- Align Commerce with the canonical five-repository architecture, including
  the one-way Permit issuer adapter, product/identity boundary, and a bounded
  M1 implementation handoff.
- Add a documentation gate for local links and canonical family-architecture
  references.
- Define the provider-neutral Commerce boundary and its relationship with
  Rivet, Glaze, Keel, and Permit.
- Add the pure payment-event projection core with idempotent replay,
  conflicting-replay rejection, refund-before-payment handling, and rights
  intents.
- Add the server-side provider adapter contract and runnable first-purchase
  walkthrough.
- Add bilingual onboarding, a canonical documentation map, security and
  operations contracts, ADRs, and three-platform CI.

