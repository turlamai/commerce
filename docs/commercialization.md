# Product-family commercialization plan

Status: implementation plan, 2026-11-13. This is not merchant admission,
a live Offer, a pricing policy or a production-readiness certificate.
Product prices and promises stay in product repositories; portfolio roles
stay in the [portfolio](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md).
The dependency graph remains owned by [Keel](https://github.com/turlamai/keel/blob/main/docs/family-architecture.md).

## One rights system, explicit purchase channels

Permit describes and verifies rights. Commerce derives versioned rights
intents from authenticated payment facts and delivers signed Permit evidence
through its issuer. Products own feature meaning, commercial policy and the
purchase/import/recovery experience. Free products do not acquire accounts
or paywalls to demonstrate the infrastructure. This plan does not restart
paused products or change existing product pricing.

Channels are adapters, not separate license implementations in every app.
The reviewed registry must distinguish product, edition/feature IDs, immutable
Offer/policy version, provider listing ID, currency and environment. Email,
provider customer IDs and store receipts are not stable product subjects.
The Offer explicitly defines cross-product and cross-platform scope.

| Path | Provider supplies | Family supplies |
| --- | --- | --- |
| Direct desktop distribution | Admitted checkout, payment/refund facts and settlement | Offer policy, signed offline rights, claim/reissue/recovery, update eligibility and support audit |
| Mac App Store In-App Purchase | StoreKit purchase/restore, signed transactions, server notifications/API | A future verified adapter, subject binding, product policy, reconciliation and optional Permit exchange |
| Free or manually fulfilled product | No automated checkout required | No commercial dependency for free products; Permit alone can support reviewed manual issuance |

[Developer ID](https://developer.apple.com/developer-id/) signing and notarization
establish publisher/distribution trust outside the Mac App Store. They do not
collect payment or grant a customer's product license. Publisher credentials,
Apple server credentials, other payment secrets and Permit keys stay separate.
Apple's store transaction verification/restoration does not supply the family's
Windows/Linux direct-sale license service. An Apple purchase does not
automatically grant an all-platform license: first review the product promise,
applicable store terms and identity/recovery contract.

## Rights profiles to validate, not prices to impose

- Perpetual desktop right with independent maintenance/update eligibility:
  update expiry does not remove use of an already eligible version.
- Continuing-service subscription with explicit paid-through and grace;
  expiry must not delete customer data.
- Local or signed trial chosen by product risk; local state is not tamper-proof.
- Team/seat/device limits with allocation, release, replacement and recovery
  owned by future management slices. A Permit limit is not a deployed seat service.

For direct desktop products, retain offline verification and credential import.
Add activation only when the actual seat/revocation policy requires it. Do not
force every buyer into a family account. Identity services own optional account
linking and recovery; Commerce consumes an authenticated stable subject.

## Customer lifecycle and failure contract

Exercise purchase, pending/unknown result, durable payment acceptance, delayed
issuance, claim, verified import, offline restart, eligible update, renewal/
upgrade, lost-file recovery, reinstall/new device, refund and support.
[Purchase progress](purchase-progress.md) describes workflow, never authorization.
Unknown results reconcile the same order rather than charge again. A bad import
preserves the previous usable credential. Recovery authenticates the claimant
through the product/identity boundary, reuses the logical entitlement and audits
reissue; knowing an email or order ID is insufficient. Retired keys continue to
verify historical rights. Refund policy states offline revocation limits and
any required lease/refresh interval.

## Apple acceptance contract (not implemented)

Prefer current StoreKit signed transactions and App Store Server Notifications
V2/API over introducing a legacy receipt-only path. Native StoreKit calls stay
in the Apple host; commercial projection stays in the Racket service. This plan
introduces no new business runtime or JS/TS service.

Before constructing a canonical event, verify the JWS signature and certificate
chain against reviewed Apple roots; validate app/bundle, environment, listing,
transaction kind and ownership policy. Decoded JSON, a client `verified` flag
or arbitrary `x5c` certificate is not evidence. Production rejects Xcode local
testing and sandbox facts. Review `appAccountToken` binding where a product
account exists; an unbound restore needs its own reviewed identity flow. Do not
trust a client transaction ID as ownership or silently require accounts.

Transaction identity and notification delivery identity need separate durable
idempotency rules. Restores must not create extra logical rights; renewals must
not extend a paid period twice. Finalize the mapping to Commerce event/order
keys only after characterizing one-time purchases, renewals, refunds and
out-of-order delivery together. Preserve provider IDs for audit/reconciliation,
not as authorization tokens. Check expiry/grace and revocation facts; a signed
purchase snapshot alone does not prove the absence of a later refund. Exercise
missed notification, crash, restore and reinstall. Xcode tests, App Store
sandbox and approved production evidence remain distinct evidence levels.

Primary references checked 2026-11-13:
[signed data and certificate verification](https://developer.apple.com/videos/play/wwdc2023/10143/),
[StoreKit verification](https://developer.apple.com/documentation/storekit/verificationresult),
[appAccountToken](https://developer.apple.com/documentation/storekit/transaction/appaccounttoken),
[server validation](https://developer.apple.com/documentation/storekit/validating-receipts-with-the-app-store).
Refresh eligibility, terms and exact API contracts before implementation.

## Ordered delivery and acceptance

Take one bounded slice at a time. A library test does not make every channel
or product commercially ready.

1. **Stable dependency boundary:** Permit #30 / Commerce #61 P1: public strict
   reader, no cross-package private imports, pinned dependency, regression and
   package/documentation gates. This does not launch a payment channel.
2. **One product's direct-sale rehearsal:** continue #4/#5 with its reviewed
   policy; do not change pilot solely because an old issue names another app.
   Pin service/product/Permit SHAs; exercise duplicate/delayed delivery, unknown
   checkout, lost claim, reissue, offline import, update eligibility, refund,
   key rotation and encrypted restore. Merchant admission and approval precede
   real charges.
3. **Signer/deployment evidence:** #10's verified-evidence implementation is
   completed; validate the deployed verifier, OS permissions and key custody.
   Preserve ADR-0020 residuals and [release gates](release-checklist.md). Fixture
   and role-selection tests do not establish deployment isolation.
4. **Apple channel:** select a real product/store Offer, then implement verified
   transactions, durable replay/projection, Permit exchange, restore/refund/
   reconciliation and approved sandbox/product evidence in separate slices.
   Developer membership alone satisfies none of these adapter gates.
5. **Second product and operations:** reproduce the lifecycle without copied
   signing/payment logic, then extract repeated client needs. Team allocation,
   delivery transports and operator UI each need demand and acceptance. A shared
   account system is not a prerequisite for every product.

Commercial acceptance means customers can buy, recover and keep eligible
offline rights through failures, while operators reconcile money, rights and
delivery without database surgery. Cross-platform CI, package checks and
recorded live/restore evidence are all required; none substitutes for another.
