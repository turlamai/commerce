# Security

Commerce crosses money, identity, and product-rights trust boundaries. Secure
defaults are part of the domain model, not deployment polish.

## Threats in scope

- forged, modified, replayed, duplicated, delayed, or reordered webhooks;
- event-id reuse with different content;
- amount, currency, offer, or subject substitution;
- test/live environment confusion;
- leaked provider secrets or Permit signing keys;
- double issuance after retry or worker crash;
- logs/backups exposing personal or payment-adjacent data;
- an operator replaying the wrong event or issuing the wrong entitlement;
- a compromised product client attempting to mint rights.

## Rules

1. Authenticate exact raw input before canonical parsing.
2. Persist the authenticated raw event and its digest before acknowledgement.
3. Use exact minor-unit integers and compare expected amount/currency.
4. Bind provider product/price identifiers to a configured Offer server-side.
5. Treat redirects and client claims as untrusted hints.
6. Make projection and outbox insertion atomic.
7. Make every consumer idempotent and crash-replayable.
8. Keep products unable to construct verified payment facts or sign credentials.
9. Redact secrets and personal data structurally before logging.
10. Separate live/test databases, secrets, keys, provider ids, and hostnames.

For Pancake, `commerce/pancake` copies and authenticates the exact raw bytes
before JSON parsing. Callers must name the environment; the verifier never
tries production and test keys in sequence. Its 45-minute past window covers
provider retries while the one-minute future window limits clock-skew
acceptance. Duplicate signature fields, duplicate top-level JSON fields, and a
signed payload whose `mode` disagrees with the selected environment fail
closed. Durable `(provider, event-id)` journal idempotency remains mandatory.

After webhook authentication, a one-time purchase is actively read through the
signed merchant GraphQL endpoint. Commerce accepts it only when order id,
completed status, environment, store, random checkout-binding reference,
provider product, succeeded payment id, currency, and exact minor-unit amount
all match server-side expectations. The binding resolves to an opaque stable
subject locally; email, redirect parameters, metadata, and provider customer
identities cannot select the entitlement owner. GraphQL responses are size and
time bounded, redirects and implicit transport retries are disabled, and
retryable provider unavailability remains distinct from terminal semantic
rejection.

Pancake authentication and active-order failures expose typed codes and minimal
metadata only.
Raw payloads, signature headers, decoded signatures, key contents, underlying
parser/crypto/transport messages, GraphQL error messages, and customer/order
values are forbidden from ordinary errors and logs. A SHA-256 payload digest
is safe correlation metadata.

SQLite journal rows are protected against application-level `UPDATE` and
`DELETE` by schema triggers. The journal API also recomputes the SHA-256 digest
from a private copy of the authenticated bytes before writing. These controls
do not replace filesystem access control, encrypted backups, or host security.

Schema v2 keeps journal evidence immutable while projections remain rebuildable
views. A projector conflict cannot alter the previous order or create issuance
work: it writes only a typed blocked marker. Order, outbox, and projected marker
writes otherwise commit or roll back together. Pending outbox rows are workflow
state, not credentials or authorization evidence.

Offer-to-Permit mapping resolves an immutable policy id and delegates closed
snapshot validation and serialization to the published `permit/issuer` API.
Commerce rejects unknown/deleted Offers, product-scope mismatch, unsupported
subscription policy, and issuer/subject/entitlement lineage mismatch before a
signer is involved. The returned bytes are the only bytes a future signer may
consume; rebuilding their JSON would violate Permit's exact-byte boundary.

## Key custody

No production private key or provider secret is committed, bundled, printed, or
stored in ordinary configuration. Environment variables are acceptable only as
a deployment injection mechanism, not as a long-term secret-management design.

Both `issuance-worker` and `issuance-result` are opaque to diagnostic
formatting, preventing accidental printing of a signing-key field or the
one-time claim token returned by a successful issuance. This does not
isolate memory or permissions: the current deployment still loads the raw
Permit signing key into the same process as the Commerce HTTP edge.
Production signing should run through a narrow signer interface so the
HTTP-facing process cannot read/export the raw key. Key identifiers and
rotation state are recorded with every issuance.

Signing authority is bounded by the verified-evidence boundary
(ADR-0020, issue #10): the issuer role re-verifies journaled provider
signatures offline with issuer-held public keys and the pinned catalog
price before any grant is signed, so a compromised HTTP edge that forges
journal, projection, or outbox rows cannot obtain or redirect a
credential: the claimed outbox Offer and subject must match the journaled
event, the subject must match the append-only checkout binding the order
was minted for, and the amount must match the pinned catalog price.
Withdrawals re-verify the journaled signed refund-query proof the same
way. Creating new checkouts for arbitrary subjects remains a legitimate
edge operation owned by the product's identity boundary; see ADR-0020
for the full list of residuals.

## Customer identity

Commerce stores an opaque stable subject id established by a verified product
or identity flow. Email, name, and provider customer ids are mappings or
display/contact data. A change of email must not create a new entitlement owner
or grant access to an existing one without a verified recovery flow owned by
the product or identity service.

## Offline limits

Commerce cannot revoke a credential held by a permanently offline, locally
controlled client. Products requiring timely refund enforcement, subscription
expiry, or device reclamation use activation leases or another explicit online
mechanism. Documentation and UI must not promise stronger control than the
system provides.

## Security evidence before production

- captured valid/invalid provider fixtures;
- replay, reordering, amount-conflict, signature-failure, and timeout tests;
- redaction tests against emitted logs and failure artifacts;
- transactional crash tests at every journal/projection/outbox boundary;
- restore rehearsal from encrypted backups;
- staging and production key-rotation drills;
- operator runbooks exercised without direct database editing.

