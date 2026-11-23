# Architecture

Commerce is a hosted commercial management plane. Its central rule is:

> Payment providers report money movement; Commerce derives commercial intent;
> Permit expresses product rights.

No layer substitutes for another.

The canonical cross-repository ownership and release rules live in the
[family architecture](https://github.com/turlamai/keel/blob/main/docs/family-architecture.md).
This document owns Commerce's internal architecture and local integration
boundary.

## System boundary

```text
Product UI
   |
   | create checkout / claim credential
   v
Commerce edge
   |--------------------------------------.
   |                                      |
   v                                      v
Provider adapter                     Claim delivery
   |                                      |
   v                                      v
Pancake / ZPAY / store              signed credential
   |
   | authenticated webhook or verified receipt
   v
Immutable event journal
   |
   v
Projection transaction
   |--------------------.
   v                    v
Order/subscription   Issuance outbox
projection               |
                         v
                   Entitlement policy
                         |
                         v
                    Permit issuer
```

## Ownership

| Owner | Responsibilities |
| --- | --- |
| Product | User-facing upgrade flow, offer selection, commercial promises, credential storage/import, local Permit policy evaluation |
| Commerce | Offer mapping, checkout orchestration, authenticated event journal, minimal projections, rights intents, issuance workflow, credential claim delivery, audit |
| Provider | Payment methods, money movement, provider ledger, billing UI, transaction tax/MoR duties where contracted, refunds and disputes |
| Permit | Credential protocol, trust verification, entitlement/trial/activation semantics, local policy evaluation, issuer primitives |
| Rivet/Glaze | Application lifecycle, UI host, secure storage primitives, distribution, update integrity |
| Keel | Transport-neutral application value/schema/lifecycle vocabulary used by desktop runtimes |
| Product/identity service | Stable subject binding, login, account recovery, and verified identity changes |

## Source of truth

There is no single database that truthfully owns every concern:

- the provider ledger is authoritative for payment facts;
- the immutable Commerce journal is authoritative for what Commerce received
  and authenticated;
- Commerce projections are rebuildable operational views;
- the entitlement lineage is authoritative for what Commerce issued;
- a verified Permit credential is the application's authorization evidence.

The system reconciles these sources; it does not blur them.

## Consistency model

Checkout completion is asynchronous. A browser redirect is user experience,
not fulfillment evidence. Only an authenticated provider event plus any
provider-required active order verification may advance commercial state.

Webhook acknowledgement means the raw event was durably accepted or an exact
retry was recognized. It does not wait for credential signing or email/claim
delivery. A projector later consumes unprojected journal sequences in order;
its order update, issuance-outbox insertion, and durable processing marker occur
in one database transaction. Issuance workers consume the outbox idempotently.

## Process and module boundaries

The repository starts as one deployable service with strict internal tiers:

```text
commerce                 pure public facade
commerce/core            deterministic model and transitions
commerce/provider        explicit server-side adapter contract
commerce/journal         durable acceptance protocol
commerce/storage         durable projection and outbox protocol
commerce/storage/sqlite  SQLite journal/projection/outbox backend
commerce/pancake         Pancake webhook authentication boundary
commerce/permit          Offer policy and Permit snapshot adapter
commerce/issuer          explicit issuer worker: claim, prepare, sign, record
commerce/server          HTTP webhook edge: authenticate, verify, journal
commerce/health          readiness snapshot and stuck-work warnings
commerce/log             structured redacted event logging
commerce/private/*       implementation-only helpers

future explicit modules:
commerce/zpay           ZPAY protocol adapter
commerce/operator       operator CLI (raco commerce ships today)
```

Physical extraction into separately versioned packages happens only when real
consumers require independent release cadence. Directory symmetry alone is not
a reason to split packages.

## Provider capability model

Adapters expose capabilities rather than pretending every provider is equal.
One-time checkout, recurring billing, partial refund, customer portal, local
payment methods, and active order lookup remain independent capabilities.

The core vocabulary grows only when at least two providers or one provider plus
an app-store receipt flow demonstrate the same durable semantic. Provider-only
data remains provider-owned.

## Failure behavior

- Invalid authentication: reject without creating a canonical event.
- Exact retry: acknowledge without a second projection or rights intent.
- Same event id, different content: quarantine and alert; never guess.
- Same order, changed offer/subject/amount: quarantine and alert.
- Unknown or deliberately deleted Offer policy: retain journal, projection, and
  outbox evidence; fail snapshot preparation before signing and expose typed
  operator action.
- Order identity conflict: preserve the previous projection, create no outbox
  work, and durably mark the journal sequence blocked.
- Issuer unavailable: retain outbox work and retry; payment state is not lost.
- Delivery unavailable: retain signed credential and retry claim notification.

## Evolution rule

The first production slice is one Pancake one-time purchase. Subscriptions and
ZPAY arrive later through the same journal/outbox boundary. Architecture is
allowed to become more capable, but never by moving provider secrets or Permit
private keys into products.


## Provider-specific current access

[ADR-0027](decisions/0027-nowpay-direct-duration.md) adds an opt-in NowPay Direct issuer path alongside the money-event pipeline. An issuer-owned active access query, private lineage/audit database and nonce-bound Permit evidence do not manufacture payment or settlement facts. The public HTTP edge never receives Permit private keys or writes that issuer database.
