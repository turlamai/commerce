# Hosted entitlement ledger read: internal contract (draft)

This is an **internal read primitive**, not a deployed public endpoint and
**not** an authorization decision. It is developed under [#21](https://github.com/turlamai/commerce/issues/21)
for product-hosted services (starting with Publy) and [#27](https://github.com/turlamai/commerce/issues/27).

## Boundary

`commerce/hosted-entitlement` exports `current-entitlement-snapshot`.

A trusted product service must **first authenticate its service identity**,
map the authenticated account to the Commerce `subject-id`, and restrict
`issuer`, `subject-type`, `subject-id`, and `offer-id` in the
`#:authorize` callback. A caller-provided account ID or product ID is never
authorization. The callback must return literal `#t` to permit a read;
everything else fails closed, before the database lookup. Do not wire this
primitive to an unauthenticated HTTP route.

The optional `#:minimum-revision` is a nonnegative revision number from the
product service's **durably remembered and authenticated** high-water mark.
When the latest stored revision is older, missing, or pending, the function
returns `status=stale-revision`. The product must fail closed or retry against
a fresh replica, **not** grant from a cached older version. This is an
anti-rollback *read fence*, not a substitute for a durable high-water mark,
transport authentication, expiry evaluation, or signature verification.

Possible status values:

| Status | Meaning | Can the client grant access? |
| --- | --- | --- |
| `absent` | No matching lineage (no minimum revision requested) | **No** |
| `pending` | Lineage exists, no recorded revision | **No** |
| `stale-revision` | Requested minimum revision not available | **No** |
| `recorded-grant` | Latest stored revision has action `grant` | **Not from this response alone** |
| `recorded-withdrawal` | Latest stored revision has action `withdraw` | **No** |
| `unknown` | Unexpected revision action | **No** |

Recorded revisions expose a revision number, entitlement ID, credential ID,
action, policy ID/version, and storage-recorded timestamp. This primitive
does **not** expose private keys, customer contact, payment provider payloads,
claim tokens, or raw order data. These fields are metadata, not proof.

## Remaining work before a production service contract

1. Authenticate service-to-service requests, including subject and product
   binding, replay protection, bounded timestamps, rate limiting, and audit.
2. Return the current **verified signed Permit envelope** and validate its
   subject, Offer/product, issuer, signature, trust-store status, lineage,
   expiry/paid-through, and effective current revision before granting access.
3. Specify explicit unavailable states for dependency outages and policy
   suspension. Never infer `paid=true` from a redirect, a snapshot row, or
   a caller-controlled field.
4. Validate cross-product and cross-account isolation, grant/withdrawal replay,
   subscription cancellation, delayed delivery, stale read, and recovery
   against both Racket and TypeScript integration fixtures.
5. Complete full CI and merchant/security release gates #4/#5/#10.

Current tests are local synthetic fixtures. Nothing here establishes a live
merchant account, a functioning product API, or production release readiness.
