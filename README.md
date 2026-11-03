# Commerce

**One commercial truth for every product — payment events in, signed product rights out.**

[![CI](https://github.com/turlamai/commerce/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/commerce/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE) ![Stage](https://img.shields.io/badge/stage-M3%20Subs-C15F3C)

**English** · [中文](README.zh-CN.md)

Commerce is the provider-neutral commercial management plane for independent
software. It gives every product one place to create checkout sessions, accept
and audit payment events, project orders and subscriptions, and turn commercial
outcomes into signed [Permit](https://github.com/turlamai/permit) rights.

Commerce is not a payment processor, merchant of record, tax engine, CRM, or
DRM system. Pancake, ZPAY, app stores, and future providers remain responsible
for moving money. Permit remains responsible for signed, locally verifiable
rights. Commerce owns the durable orchestration between them.

**Provider-neutral. Event-driven. Rights-first.**

## Start here

Use Commerce only when a product needs durable payment-to-rights orchestration. It is one headless service with explicit provider and Permit issuer boundaries; it is not a payment processor, merchant of record, identity system or proof of merchant eligibility.

[Fit, maturity, upgrades and support](docs/USING.md) · [简体中文](docs/USING.zh-CN.md)

## Quick start

The current implementation provides the pure event core, replay/conflict protection,
order projections, rights intents, a provider boundary, a durable SQLite raw
event journal, exact-byte Pancake webhook authentication, active Pancake
one-time-order verification, transactional durable projection/outbox storage,
version-pinned Offer-to-Permit snapshot mapping, an owner-safe issuance-outbox
lease state machine with the transactional entitlement-lineage writer, the
explicit Permit issuer worker that signs recorded bytes, records them as
durable credential evidence, and hands the customer a one-time claim token,
the refund and operator replay surface, tests, and one runnable purchase
walkthrough.

```bash
git clone https://github.com/turlamai/commerce.git
cd commerce
raco pkg install --auto --name commerce --link "$PWD"

racket examples/first-purchase.rkt
```

Expected result:

```text
order ord_demo_001: paid
rights intent: grant taskly-pro-lifetime to customer-demo
duplicate webhook: ignored
```

Continue with **[Getting started](docs/getting-started.md)**. The
[documentation map](docs/README.md) identifies the canonical guide for every
architectural and operational question.

## Why Commerce?

A product can integrate one checkout in an afternoon. A product family cannot
safely repeat payment verification, retries, refunds, subscription renewal,
credential recovery, and licence issuance in every application.

Commerce creates one durable boundary:

- **Products speak offers and rights** — they never embed provider API keys or
  signing keys.
- **Providers speak payments** — each adapter verifies its native protocol and
  emits the same small canonical event vocabulary.
- **Permit speaks authorization** — Commerce requests complete signed rights
  snapshots; applications verify them locally.
- **Every transition is auditable** — raw events are retained, duplicate
  delivery is harmless, conflicting replay fails closed, and issuance is an
  explicit outbox step rather than a webhook side effect.

## Where it fits

```text
                         Product
                    /       |       \
              Rivet/Glaze  Permit  Commerce client
                    UI      verify       |
                                         v
                                 Commerce service
                              /          |          \
                       Pancake         ZPAY       app stores
                              \          |          /
                               verified payment events
                                         |
                                  rights intent
                                         |
                                  Permit issuer
                                         |
                              signed Permit credential
```

The dependency direction is deliberate:

```text
product  -> Rivet or Glaze
product  -> Permit
product  -> Commerce client       (only when online commerce is wanted)

Commerce service -> payment providers
Commerce service -> Permit issuer

Rivet / Glaze / Keel -X-> Commerce
Permit               -X-> Commerce
```

See [Architecture](docs/architecture.md) and
[Family integration](docs/family-integration.md) for the local ownership rules;
the [family architecture](https://github.com/turlamai/keel/blob/main/docs/family-architecture.md)
is the canonical five-repository contract.

## Core vocabulary

| Concept | Meaning |
| --- | --- |
| Product | Stable software identity, such as `taskly` |
| Offer | Something a customer may buy, such as `taskly-pro-lifetime` |
| Provider mapping | The Pancake/ZPAY/store identifiers that implement an offer |
| Payment event | A verified, immutable fact received from a provider |
| Order projection | Commerce's minimal local view of commercial state |
| Rights intent | An auditable request to grant, renew, replace, or withdraw rights |
| Issuance | The eventual signed Permit credential and its delivery state |

Commerce does not clone a provider's entire product catalog or customer
database. Provider objects remain the source of payment facts; Commerce stores
only the identifiers and projections required for deterministic orchestration.

## Public modules

```racket
(require commerce)           ; pure domain model and state transitions
(require commerce/provider)  ; server-side provider adapter boundary
(require commerce/journal)   ; durable event-acceptance contract
(require commerce/storage)   ; durable projection/outbox operations
(require commerce/storage/sqlite) ; SQLite service-storage backend
(require commerce/pancake)   ; Pancake authentication and active order proof
(require commerce/permit)    ; reviewed Offer policy to Permit snapshots
(require commerce/issuer)    ; explicit issuer worker: claim, sign, deliver
(require commerce/operator)  ; operator find/explain/redrive surface
(require commerce/log)       ; structured redacted event logging
(require commerce/health)    ; readiness snapshot and stuck-work warnings
(require commerce/server)    ; HTTP webhook edge and claim portal
(require commerce/reconcile) ; bounded provider-facts reconciliation
```

The default `commerce` facade does not expose provider secrets, raw webhook
acceptance, network listeners, databases, or Permit signing. Those capabilities
belong to explicit server-side modules.

## Alipay Vibe Pay (integration candidate)

The optional Alipay refund operation ledger prevents repeating a money-moving
request after a crash or timeout and accepts rights withdrawal only after a
signed full-refund query. It does not activate refunds or merchant accounts.


The Alipay operator checkout sample requires a **private, approved capability
record** before minting an order. Its shipped template refuses by default;
merchant eligibility and live payment are still external release gates.


The optional server-side [Alipay Vibe Pay Basic Collection adapter](docs/alipay-vibe-pay.md)
is implemented as a signed checkout/request boundary, RSA2-confirmed active
query client, strict callback parser and durable journal-based callback
listener. **Its CI and merchant admission are still pending**, and it must
not be represented as production-ready. It uses Racket, not Node/npm.

## Current status

Implemented now:

- exact integer minor-unit money values and stable offer identities;
- verified canonical payment events;
- provider event idempotency and conflicting-replay rejection;
- order projections that tolerate refund-before-payment delivery;
- deterministic `grant` and `withdraw` rights intents;
- a provider adapter contract and mock walkthrough;
- a durable SQLite raw-event journal with digest verification, exact replay,
  conflicting-replay rejection, and database-enforced immutable rows;
- SQLite schema v8 with versioned migrations from v1-v7, deterministic journal
  projection, atomic order plus issuance-outbox writes, and append-only,
  contiguous entitlement-lineage evidence;
- exact-byte Pancake RSA-SHA256 verification with explicit environment keys,
  bounded replay tolerance, mode binding, and redacted typed failures;
- signed Pancake merchant GraphQL reads that bind a completed one-time order to
  its store, environment, external checkout reference, product, succeeded
  payment, exact currency/amount, stable subject, and Offer before constructing
  a canonical payment event;
- an explicit `commerce/permit` adapter that validates version-pinned Offer
  policy through Permit and prepares complete revision-0 grants or withdrawal
  successors that expire at issuance, plus their exact serialized bytes;
- an owner-safe issuance-outbox lease state machine — exclusive claims with
  observable attempts, expired-lease reclaim, owner-checked completion, and
  typed release — whose completion appends the lineage root plus revision
  zero, or exactly one successor, together with outbox completion in one
  transaction, reconciling repeated completion to the recorded revision;
- the explicit `commerce/issuer` worker: deterministic lineage and
  credential ids, snapshot preparation, deterministic Ed25519 signing of the
  exact recorded bytes outside the claim transaction, typed refusal of
  deterministic dead ends before signing, bounded transient backoff, and
  crash reconciliation;
- one-time claim delivery: append-only signed-credential evidence, a
  random claim token stored only as its digest, explicit
  ready/claimed/expired fulfillment states with idempotent notification
  marks, and typed claim fulfillment that never advances a lineage
  revision;
- the refund and operator replay surface: redacted order explanations,
  outbox enumeration, and bounded redrive that reuses the immutable
  journal without ever editing a projection row or rewinding finished
  work;
- structured, redacted-by-construction event logging with operational
  correlation ids (journal, projection, lease, and claim transitions);
- a read-only readiness snapshot with typed stuck-work warnings and the
  `raco commerce` operator CLI (find, explain, redrive) as the supported
  headless workflow;
- operational evidence tools: consistent database snapshots, restore
  rehearsals that verify integrity and counts, expired-claim retirement,
  and a rotation drill proving one lineage carries revisions signed by
  different key ids;
- an HTTP webhook edge and claim portal: authenticate exact bytes,
  resolve the durable checkout expectation (schema v6, append-only
  bindings), actively verify the order, journal idempotently, and
  acknowledge with total status mapping; the portal fulfills one-time
  claims over HTTP (404/409/410 for unknown, reused, and expired
  tokens);
- operator audit on schema v8 (append-only action/operator/reason
  evidence) and bounded claim reissue for the same credential with
  audited fresh tokens;
- bounded provider reconciliation: signed order-fact reads compared
  against projections with typed differences, never mutating durable
  state;
- subscription semantics: provider-reported paid-through windows,
  idempotently keyed renewal revisions that expire at the paid window,
  and cancellation successors that lapse at period end (ADR-0014);
- one runnable end-to-end journey over the real protocol boundaries
  (`examples/full-journey.rkt`) and the operator runbook
  ([docs/runbook.md](docs/runbook.md));
- bilingual entry documentation, normative architecture, and CI gates.

Remaining external integration and release gates:

- live provider sandbox credentials and captured checkout-to-claim evidence;
- provider-facing checkout creation (durable bindings already exist; checkout
  UI belongs to the product);
- outbound delivery such as email (the HTTP claim portal already exists);
- ZPAY, app-store and other adapters, only after measured product demand;
- a graphical operator UI, if operation through the existing CLI proves
  insufficient;
- production deployment and operational canary evidence. No payment-provider
  certification or production-readiness claim is made.

The HTTP edge, claim portal, operator replay/audit and subscription projections
listed above are implemented surfaces, not remaining TODOs. Their local/fixture
coverage is distinct from a live provider integration. The gptp-studio
payment-evidence-derived maintenance window was implemented in
[merged PR #2](https://github.com/turlamai/commerce/pull/2) (closing
[issue #1](https://github.com/turlamai/commerce/issues/1)); it is fixture-tested,
not a live checkout. The next release gates are provider admission,
trusted signing authorization and a real purchase/claim canary.
[ROADMAP.md](ROADMAP.md) and the
[release evidence checklist](docs/release-checklist.md) own the sequencing
and verification requirements.

## Deployment

`examples/service.rkt` supports `COMMERCE_ROLE=edge|issuer|all`. Run `edge`
(HTTP and claim portal, no Permit private key) and `issuer` (projector and
signer, no HTTP listener) under separate OS identities with one SQLite store.
`all` preserves a local combined walkthrough. See [deploy/README.md](deploy/README.md)
for systemd units and [ADR-0020](docs/decisions/0020-split-service-roles.md)
for the unresolved shared-writable-database trust boundary. Neither separate
processes nor a green CI by themselves prove production signing isolation.
`/readyz` renders the readiness snapshot; crash replay remains durable.

## Security reporting and release status

Please report suspected security vulnerabilities privately through
[SECURITY.md](SECURITY.md), not in public issues. The
[release checklist](docs/release-checklist.md) records the still-unproven
merchant admission, signer trust and live purchase gates; a successful local
walkthrough does not establish production readiness.

## Development

```bash
raco pkg install --auto --no-docs --name commerce --link "$PWD"
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/storage.rkt commerce/storage/sqlite.rkt commerce/pancake.rkt \
  commerce/permit.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

Before changing a boundary, read [AGENTS.md](AGENTS.md) and
[Architecture](docs/architecture.md). Every public API change ships with tests,
English and Chinese entry documentation where affected, and the corresponding
normative document update.

## License

Apache-2.0. See [LICENSE](LICENSE).
