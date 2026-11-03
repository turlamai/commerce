# Durable hosted entitlement anti-rollback (product-server component)

The opt-in module **commerce/hosted-consumer/sqlite** provides a persistent
high-water mark for a product backend that consumes Commerce's authenticated
hosted proof endpoint. It is not a paid flag, a credential cache, a billable
account registry, or an authorization decision.

## Signed active and withdrawal evidence

The hosted proof endpoint distinguishes two signed outcomes with exact Permit
envelope evidence:

- **verified-proof**: latest usable signed grant; the product must STILL run
  its own Permit feature, edition, add-on, update and quota policy.
- **recorded-withdrawal**: latest signed withdrawal; **always denies** access,
  even though a credential and revision are returned to prove the high-water
  mark. The product records that newer revision to reject replays of an older
  positive grant.

No envelope is returned as authorization for absent, pending, unresolved
refund, stale lineage, unavailable or invalid-proof states. The consumer must
fail closed on all of them.

## Protocol

1. The product backend authenticates the customer and binds an opaque stable
   account subject and product Offer to the registered service identity.
2. The backend sends an authenticated, replay-protected hosted proof request
   via TLS. It includes its previously stored minimum revision AND expected
   entitlement ID, if known.
3. On a signed active or withdrawal response, the consumer independently
   verifies the Permit envelope with a pinned public trust store, matches
   issuer, subject type/ID, product grants, entitlement identity and revision,
   then atomically records the greatest observed revision per exact
   service/issuer/subject/Offer/product tuple.
4. A lower revision or changed entitlement identity fails closed. An exact
   replay is idempotent. A process restart cannot clear the high-water mark.
5. A current active response still needs product-owned permission checks
   and atomic quota consumption. No positive result may be cached indefinitely;
   an outage or unprojected refund denies paid admission.

Provision the SQLite file once with
**initialize-sqlite-hosted-watermark-store!**. Use the public read function
**read-hosted-entitlement-watermark** to retrieve the pinned entitlement
identity and minimum revision for the next request. Missing runtime data
must not be silently replaced with an empty database. Protect and back up
the file; rotation and administrative lineage reset require an explicit,
separately reviewed procedure.

The implementation is Racket-only reference code for Racket product services.
Publy's TypeScript backend still needs its own durable equivalent and actual
integration tests; do **not** bundle Racket inside the Obsidian/CLI client or
call this production adoption. The live merchant, deployment and signer
operational gates remain NO-GO under #4/#5/#21.
