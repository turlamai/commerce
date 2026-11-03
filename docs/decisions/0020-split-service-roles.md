# ADR-0020: Split Commerce edge and issuer service roles

Status: **accepted as an incremental hardening step; not the final trust boundary**

## Problem

The former example assembled the public HTTP listener, provider merchant
credential, payment projector, and Permit private signing key in one process.
Compromise of that HTTP-facing process therefore exposed an unrelated
commercial signing secret. Signing and claim delivery remain distinct from
webhook processing in the application model, but not in OS privileges.

## Decision

The service accepts `COMMERCE_ROLE=all|edge|issuer`. `all` retains the
combined local demonstration. An edge-only process reads Pancake credentials
and webhook verification keys, but never resolves `PERMIT_PRIVATE_KEY_PATH`,
creates a Permit signer, or starts the issuance thread. An issuer-only process
reads the Permit signing key and a pinned product policy catalog, runs the
projector and outbox worker, and starts **no HTTP listener**. Both roles share
one SQLite WAL database and honor the same environment and database path.

Two different unprivileged OS identities, mutually inaccessible key files,
separate environment configuration and systemd hardening are required to
obtain actual process-level key confidentiality. Starting two processes
under one account or running two root containers with shared secrets does not
provide the intended isolation. The examples have no privileged key-export
endpoint.

## Security boundary and limitations

This design narrows *key confidentiality exposure*, not signing authority.
Both processes still have write access to the same database. A compromised
edge with arbitrary database write access could forge payment journal,
projection or outbox records, and thus trick the issuer into signing
unauthorized rights. Database triggers and idempotency protect ordinary
application mistakes, not arbitrary malicious SQL from a writable role.
No claim of a fully isolated trustworthy signer is warranted.

The verified-evidence milestone below is now implemented (issue #10):
the issuer role re-verifies journaled payment evidence offline before any
grant signing, so an HTTP-process database writer cannot induce a
credential without a genuinely provider-signed payment for the exact
catalog price. Tested by direct database forgery of journal and outbox
rows, tampered amounts and statuses, retargeted outbox intents, deleted
and unknown Offers, missing evidence, and unconfigured verifier keys —
every forged path fails closed with a typed refusal and no lineage or
revision is written.

Issue #38 closed the remaining forgery gaps. The issuer now also fences
the claimed outbox subject against the journaled event and re-derives
the subject from the append-only checkout binding (which always carried
no-update/no-delete triggers and a unique merchant id — rebinding an
existing checkout was never possible), so a genuine payment or signed
refund proof can no longer be redirected to a different subject by a
forged journal row or a retargeted outbox row. Withdrawal intents now
re-verify the journaled signed refund-query proof (request id recovered
from the `refund:<id>` event id, settlement time cross-checked), closing
the forged-refund denial-of-service window for providers with offline
refund verification.

Remaining limitations, recorded honestly:

- Creating a *new* checkout binding for any subject remains a legitimate
  edge operation: whoever controls checkout creation controls who a new
  payment is minted for. That is the product's identity boundary (issue
  #21 owns the account mapping), not something Commerce can authenticate
  on its own.
- Pancake amounts are anchored to the Offer price, not to the payment
  webhook body (the body does not carry the payment amount); the signed
  webhook, journal event identity, binding, and catalog price are the
  anchors. Pancake refunds verify offline through the signed
  `refund.succeeded` webhook the same way (issue #40); Commerce never
  initiates refunds — the REST refund-ticket endpoints stay out of
  scope, and partial refunds fail closed at the edge.
- Providers without offline verification for a row kind still fail
  closed when a verifier is wired (`evidence-provider-unsupported`,
  `evidence-kind-unsupported`); running without a verifier remains
  available only as an explicit deployment choice.

## Expected behavior

- `edge`: requires provider/HTTP configuration and shared database;
  **does not require or read any Permit private key path**.
- `issuer`: requires Permit issuer, trust store, private key, policy catalog
  and shared database; **does not require provider keys or bind HTTP**.
  The bundled example uses a placeholder catalog and explicitly refuses
  production issuance until replaced with a reviewed real-product policy.
- `all`: backward-compatible for `COMMERCE_ENVIRONMENT=test` mock/local
  walkthroughs only; `production` refuses it before reading secrets or
  opening storage, even if the operator leaves `COMMERCE_ROLE` unset.
- A missing or invalid role fails closed on startup. No role is allowed to
  silently fall back to `all` after invalid input.
- Webhook acceptance remains durable before acknowledgements, and signing
  stays asynchronous. A crashed issuer is restarted by the service manager.
  An issuer restart reclaims expired outbox leases; clients and operators
  must not issue another charge for an unknown entitlement outcome.

## Verification and release gate

Unit tests check role selection, invalid roles and forbidden role
capabilities. CI compiles the role-selectable example on all supported
Racket versions and OSes; a Docker build exercises packaging. These checks
do not prove OS permission isolation or live merchant behavior. Before
any production cutover, inspect effective `systemd` permissions, verify
that the edge OS identity cannot open the issuer private key, ensure
the issuer has no listening socket, rehearse WAL permissions and multi-process
restart/recovery on a staging database, and record exact artifact SHAs.

The original combined service unit remains a compatibility demonstration.
See `deploy/README.md` for the opt-in split unit templates.
