# Roadmap

Commerce advances through complete vertical slices. A milestone is not complete
until code, tests, operator evidence, and user documentation agree.

M1-M3 have implemented protocol and local/fixture surfaces, including the
HTTP edge, claim portal, operator audit with reissue, and provider
reconciliation. This is not a claim of live provider or production validation.
Remaining external release gates include: live sandbox credentials, provider API contracts for
checkout creation and additional channels (ZPAY, app stores), and
delivery transports. Those open on measured demand; keep the honest-gap
lists in both READMEs current until then.

## M0 — Architecture foundation

- [x] Family dependency and ownership boundary
- [x] Stable product/offer vocabulary
- [x] Exact money representation
- [x] Verified canonical payment events
- [x] Duplicate and conflicting replay behavior
- [x] Minimal order projection and rights intents
- [x] Provider adapter contract and mock walkthrough
- [x] Bilingual onboarding and CI gates

## M1 — Pancake one-time purchase

- [x] Immutable raw webhook journal
- [x] Pancake signature verification with captured protocol fixtures
- [x] Active order verification before fulfillment
- [x] Durable order projection and transactional issuance outbox
- [x] Offer-to-Permit policy mapping
- [x] Permit credential issuance and one-time claim delivery
- [x] Refund and operator replay flow
- [x] Local/fixture end-to-end journey and runbook
- [ ] Live provider sandbox checkout-to-claim evidence

## M2 — Operational baseline

- [x] Structured redacted logs and correlation ids
- [x] Health/readiness endpoints and stuck-outbox inspection
- [x] Encrypted backups with restore rehearsal
- [x] Key rotation and provider-secret rotation drills
- [x] Minimal operator CLI: find, replay, reissue, explain
- [x] Data retention and privacy export/deletion procedures

## M3 — Subscriptions

- [x] Paid-through projection and renewal revisions
- [x] Cancellation-at-period-end semantics
- [x] Failed-payment grace policy
- [x] Activation lease refresh where timely enforcement is required
- [x] Upgrade/downgrade proration represented without provider leakage

Grace is represented by the provider-reported paid-through window (grace
lives inside the window the provider grants during dunning); activation
lease refresh is a product-level choice under Permit's activation
semantics; proration is computed at checkout and enters Commerce as
ordinary payment facts. Additional channels begin only after measured
product demand, per M4.

## M4 — Additional channels

The [commercialization plan](docs/commercialization.md) defines the family-wide
rights and recovery goal, direct-sale versus Apple ownership, and an ordered
acceptance sequence. Apple Developer membership does not implement a store
adapter; no existing product gains a paywall from this roadmap.

- [ ] ZPAY one-time purchase adapter
- [ ] Apple App Store receipt exchange
- [ ] Google Play receipt exchange
- [ ] Microsoft Store receipt exchange

Additional channels begin only after measured product demand. Capability
differences remain explicit; Commerce will not pretend every provider supports
subscriptions, partial refunds, or the same customer identity model.


## Next integration handoff

The gptp-studio payment-evidence-derived maintenance window was implemented
in merged PR #2 (issue #1 is closed). Do not reopen the completed policy slice
to substitute for live-product evidence. The remaining next milestone is an
approved first commercial canary, blocked by provider admission (#5), a
deployed signing-evidence and OS-permission verification (the implementation
in #10 is complete; see ADR-0020), and a live
payment-to-claim/import/recovery drill (#4). Pin Commerce and Permit commits
and the reviewed product policy before the drill.

Capture authenticated provider order evidence with secrets redacted; prove
duplicate delivery, delayed retry, claim reissue, offline import, maintenance-
window eligibility, refund disposition and backup restore. Record the exact
provider mode, product/service SHAs, commands and operator evidence outside
public Git history, linking only redacted records. Follow
[release evidence](docs/release-checklist.md). A fixture journey must never be
labelled a live transaction; absent merchant approval and credentials remain
explicit NO-GO gates.
