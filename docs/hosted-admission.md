# Hosted service permission admission (internal)

This module adds product-neutral decisions over **verified signed Permit
proofs**, not purchase status. It complements PR #28 (scoped ledger lookup)
and PR #30 (signed proof and refund fail-closed checks). A real deployment
must authenticate the requesting service separately, as outlined in PR #31.

`commerce/hosted-admission` exports `current-hosted-right-admission`,
with issuer, stable subject type/id, Offer, product ID, exact right kind and
right ID, server-side service `#:authorize`, trusted Permit store, and
trusted UTC `#:at`. Optional `#:minimum-revision` and
`#:expected-entitlement-id` are high-water fences that must be maintained
durably by the authenticated product service. See
[hosted entitlement read](hosted-entitlement-read.md) and
[verified Permit proof](hosted-permit-proof.md).

## Supported rights

| Right kind | Permit decision | Inputs |
| --- | --- | --- |
| `feature` | `feature-entitled?` | Product + named feature; `#:published-at` when policy requires publication window |
| `edition` | `edition-entitled?` | Product + exact edition |
| `addon` | `addon-entitled?` | Product + exact addon |
| `update` | `update-entitled?` | Product + **required** `#:published-at` timestamp (the right ID is an opaque request label) |

No product names, paid plans, prices or feature lists are hardcoded in the
production module. Product Offer/catalog policy is issuer-owned and version
pinned; feature publication evidence must be maintained by the product
owner, not accepted from an untrusted client. This module currently checks
*direct product grants only*, not a product-family alias.

The function returns only `allowed` and `status` when it denies a right.
A granted right additionally exposes an entitlement ID and revision so a
trusted backend can persist its high-water mark. It never returns raw payment
events, claim tokens or signed credentials to the product's UI.

A `not-entitled` result is not an error and never grants access. An invalid
Permit policy or bad timestamp returns `policy-invalid`. The upstream
proof reader propagates explicit no-access states such as `absent`,
`stale-revision`, `lineage-mismatch`, `refund-pending`,
`not-usable`, and `recorded-withdrawal`.

**Still missing before end-user launch:** authenticated HTTP route and
service key registry, durable high-water mark management, atomic consistent
reads under concurrent refund writes, signer authorization isolation (#10),
and product-side integration/acceptance (#21/#27). The test-only Publy Offer
and price are synthetic and do not approve a commercial price or feature.
External merchant and real-payment gates #4/#5 are not bypassed.
