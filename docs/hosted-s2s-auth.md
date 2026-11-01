# Hosted-service request authentication (transport-neutral foundation)

**Development-only API.** This module does not open a web endpoint, activate
checkout, or grant any product permission. It supplies authenticated request
verification for a future service-to-service (S2S) hosted-entitlement bridge
(#21), independent of Permit credential-signing keys (#10).

## Wire contract

`commerce/hosted-auth` exposes `hosted-request-mac` (client) and
`verify-hosted-service-request` (server). The MAC is **HMAC-SHA256** with a
service-specific random secret of **at least 32 bytes**. Provision secrets
outside the source tree with independent permissions. Never reuse a Permit
issuer key, merchant key, or update signing key.

The authenticated message begins with the literal UTF-8 domain
`commerce-hosted-s2s-v1\n` and contains **11 length-prefixed byte fields**
in this exact order: service ID, HTTP method, canonical path (including
query string if the route uses one), decimal Unix timestamp in whole
seconds, base64url nonce, issuer, subject type, subject ID, Offer ID, product
ID, raw HTTP body. Each field is `byte-count:raw-bytes`. This is
unambiguous even if a string contains colons or newlines.

The HTTP adapter **must** sign/verify the exact normalized route semantics
and raw body actually received. It must not trust client-supplied `method`
or `path` metadata, re-serialize JSON before verification, or grant rights
based on an arbitrary account/Offer/product passed in a query string.
Bound request limits: 1 MiB body, 2048-character path and up to 256
characters per opaque scope identifier.

## Server responsibility

A trusted service key registry resolves `service-id -> HMAC secret`. Never
resolve a caller-supplied secret; rotate each service key independently and
revoke it when compromised. `#:allow-scope` authorizes the exact **six-part**
tuple (service ID, issuer, subject type, subject ID, Offer ID, product ID)
based on server-side service identity and subject mapping. Only literal
`#t` is accepted.

Timestamp validity is checked against the *trusted server* `#:now`, with a
default ±300-second window (hard maximum 900 seconds). Nonces must be
16–128 characters drawn from ASCII base64url alphabet. After a valid MAC
and scope authorization, `#:claim-once!` must atomically and **durably**
record `(service-id, nonce)` until at least `timestamp+window+1`. The
callback must guarantee that only the first claim returns literal `#t`;
fail closed on storage outage, duplicate claim, expiration or unexpected
result. A memory hash is suitable for a unit test only, **not production**
or multi-node replay protection.

## Durable replay implementation

`commerce/hosted-replay/sqlite` provides a multi-process replay callback
using SQLite's unique constraint and an immediate transaction. Run
`initialize-sqlite-hosted-replay-store!` **once during explicit provisioning**
on an edge-only database path, then use
`make-sqlite-hosted-replay-claimer` to construct
`#:claim-once!`. The verifier passes the computed expiration value; the
store uses a trusted clock, rejects already-expired claims and removes
expired rows before each atomic insert.

A running verifier opens the existing database read/write and never silently
creates an empty replacement. A deleted or inaccessible replay database
must deny requests. Startup also refuses a missing or unprovisioned table.
Keep this database separate from issuer secrets and under access control.
Back it up or rebuild it only with an explicit maintenance procedure:
resetting replay state inside a live MAC timestamp window can enable
duplicate admission. Tests use synthetic clocks and a temporary database.

The verifier returns only `#t` for an authenticated, scoped and newly
claimed request. All other outcomes deny access; no key material or MAC is
returned. Use TLS, proxy/network access controls, per-service rate limits,
audit logs with identifiers but no keys, and secret rotation.

## Integration gates

This is not a standalone HTTP route or a production-ready S2S service.
Remaining work includes:

- Bind the verifier to Commerce HTTP handling with a registered fixed route,
  authenticated key registry, explicitly provisioned replay database and secure transport;
  ensure nonce claim and entitlement read use intended transactional policy
- Connect authenticated service identity to PR #30's signed Permit proof
  reader, not merely PR #28's non-authoritative ledger snapshot
- Authenticate service/operator principals independently of provider webhook
  secrets and issuer keys; test multi-instance replay and clock skew
- Confirm issuance authority separation (#10), external merchant admission
  (#5), sandbox/real payment lifecycle (#4/#23) and end-product integration
  (#27) before a production go-live

All examples and test keys are synthetic. The implementation does not claim
merchant eligibility, a working production backend, or permission to charge.
