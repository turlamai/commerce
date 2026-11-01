# Hosted Permit proof read (development contract)

This module is the second, stacked development slice for [#21](https://github.com/turlamai/commerce/issues/21) and [#27](https://github.com/turlamai/commerce/issues/27).
It builds on the scoped ledger reader in PR #28. **No HTTP route is
exposed**; the hosting service is responsible for authenticating its own
service principal, setting the trusted server clock, and binding its internal
account ID to Commerce's stable subject ID.

## API

`current-verified-entitlement-proof` in `commerce/hosted-proof` takes a
storage handle and an explicit tuple of issuer, subject type, subject ID,
Offer ID and product ID, plus `#:authorize`, a Permit trust store and the
server-supplied `#:at` time.

`#:authorize` receives **five arguments** including the product ID. It
must return literal `#t` only for the product/service's authorized account.
All other outcomes refuse the read before a ledger existence check. No
user-controlled query string, payment success redirect, or public product ID
can authenticate the caller. Use TLS and a dedicated authenticated S2S
transport when the endpoint is implemented.

The caller can supply a previously authenticated
`#:expected-entitlement-id` and `#:minimum-revision` to fail closed on
changed lineage or stale ledger replicas. These pins must be stored
durably by the trusted product service, not accepted from an arbitrary client.

When the latest recorded revision is a grant, Commerce looks up its **exact
stored signed Permit envelope**, verifies it through Permit's trust-store
and credential verifier (including key revocation, key purpose, signature,
issuer and issuance window), and checks its signed bytes and identities
against the latest ledger revision and the requested subject. It also checks
the direct product scope in signed grants and Permit's `credential-status`
at the trusted server time. This slice deliberately refuses a family-only
grant until the product family's mapping is independently registered.

A `verified-proof` response contains the signed Permit envelope, its
entitlement ID and revision. The product must still enforce the requested
edition, features, quotas, subscription/business policy and current
high-water mark. It is **not** evidence of merchant admission or a guarantee
that a disconnected copy has received the latest withdrawal.

Other outcomes include `invalid-proof`, `proof-unavailable`,
`not-usable`, `stale-revision`, `lineage-mismatch`, or the prior
non-authoritative ledger statuses (including `recorded-withdrawal`).
All mean **no product access granted**.

## Still required before production

- Authenticated/replay-protected S2S HTTP transport with service identities,
  rate limiting, audit, and tight subject/product binding
- Durable, trusted high-water mark management and atomic read consistency
  under concurrent refunds and storage replica lag
- Verified product-family grants, suspension, period-based quota admission,
  and product-specific service integration fixtures
- Independent signing-intent authorization and database-writer separation
  (#10); the shared writeable database is not a signer trust boundary
- Full CI on the exact head plus separate real merchant/provider acceptance
  (#4/#5/#23)

Tests use generated keys and mock payment evidence. No live payment or
production secret is included in this change.
