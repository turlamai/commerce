# Authenticated hosted Permit proof HTTP endpoint (development)

Commerce now has a **dedicated, opt-in HTTP listener** for trusted internal
product services. It is deliberately separate from payment webhooks and the
Permit issuer process. It never reads an issuer private key.

## Route

`POST /v1/hosted/proof` (no query parameters). The request is a UTF-8 JSON
object with exactly these seven keys:

```json
{
  "issuer": "com.example",
  "subject_type": "account",
  "subject_id": "account-from-trusted-service-map",
  "offer_id": "example-pro",
  "product_id": "example",
  "minimum_revision": null,
  "expected_entitlement_id": null
}
```

For a previously authenticated entitlement lineage, set
`minimum_revision` to a nonnegative integer and
`expected_entitlement_id` to the previously observed stable ID. A
product service must maintain both in durable trusted storage. These
fields are **not** a caller-controlled paid flag.

The body is parsed by the pinned Permit's strict JSON scanner, which
rejects duplicate object members, non-UTF-8 data, trailing tokens and
unknown fields; the wire encoding is authenticated as **raw bytes** before
any Commerce entitlement or claim lookup.

Required HTTP headers (exactly one each):

```
x-commerce-service-id: <registered-service-id>
x-commerce-timestamp: <Unix-seconds>
x-commerce-nonce: <unique-base64url-16-to-128-chars>
x-commerce-mac: <64 lowercase hex characters, HMAC-SHA256>
```

The MAC is calculated using `commerce/hosted-auth` over **POST**, the
literal route path, the timestamp, nonce, service ID, all five JSON scope
fields, and the exact unmodified HTTP body bytes. See
[hosted S2S authentication](hosted-s2s-auth.md) for the canonical binary
length-framing contract. Signed method, path and body are taken from the
actual HTTP request—not a caller-supplied metadata field. Duplicate
authentication headers refuse authentication.

The service registry must resolve a server-held random HMAC secret of
at least 32 bytes for that service ID. Scope authorization must
independently bind **the authenticated service** to issuer, subject
type/id, Offer and product. Production setups must not use a callback
that accepts arbitrary subject IDs or all Offers for a service.

## Response behavior

- `200`: signed proof or a typed no-access result. A
  `status="verified-proof"` response contains the exact verified Permit
  envelope plus lineage/revision metadata. Other statuses (including
  `refund-pending`, `recorded-withdrawal`, `stale-revision`,
  `invalid-proof`, `absent`, `not-usable`) are **not** an entitlement.
- `400`: invalid payload or unsupported JSON schema.
- `401`: untrusted MAC, invalid timestamp, duplicate nonce, unavailable
  replay store, or unauthorized account/Offer/product. No data lookup.
- `404`: unexpected route or method.
- `503`: entitlement storage or Permit verification subsystem exception.

A verified proof is not a feature/edition/quota permission: product services
must apply Permit policy or the hosted admission API from PR #33 before
enabling specific capabilities.

## Wiring and deployment

`commerce/hosted-http` exports:

- `make-hosted-proof-http-endpoint` with `#:storage`, a public
  `#:trust-store`, `#:resolve-key`, `#:allow-scope`, and a **durable**
  `#:claim-once!` (provided by `commerce/hosted-replay/sqlite`).
- `handle-hosted-proof-http-post` for deterministic, isolated tests.
- `serve-hosted-proof-http-endpoint` for an actual standalone listener;
  it defaults to `127.0.0.1`. A caller must supply a port and must retain
  the returned shutdown procedure.

The runtime must explicitly provision the nonce database first using
`initialize-sqlite-hosted-replay-store!`. Missing nonce storage refuses
authentication; the runtime must never silently initialize an empty replay
database. Configure OS filesystem rights, TLS/reverse proxy, service key
distribution/rotation, ingress limits and network allowlists outside the
library. No production product credential, paid Offer or private signing key
belongs in the edge HTTP process.

This is the transport integration layer, not evidence of the full hosted
service being production-ready. Follow-ups include a managed service registry,
durable authenticated consumer high-water marks, transaction-consistent
journal/refund reads, per-product policy admission, independent issuer
signing intent authorization (#10), and final product/merchant validation
(#4/#5/#21/#27). Offline fixture tests cannot replace those gates.
