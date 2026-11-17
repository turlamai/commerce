# Permit integration

Commerce consumes Permit's issuer-side API; Permit never depends on Commerce.

## Flow

```text
rights intent (claimed issuance-outbox row)
    |
    v
resolve Offer entitlement policy
    |
    v
load entitlement lineage and highest issued revision
    |
    v
construct a complete next rights snapshot
    |
    v
permit/issuer signs exact payload bytes
    |
    v
storage-complete-issuance-work! records the revision + completes the row
```

`commerce/issuer` is the explicit worker that runs this flow. It claims
work through the storage lease, fails deterministic dead ends before any
signing, signs the exact recorded bytes with Ed25519 determinism, and
completes through the transactional lineage writer — recording the signed
envelope and a one-time claim in the same transaction. A crash after
signing is safe: the reclaiming worker re-signs identical bytes and the
recorded revision converges. The claim token reaches the caller exactly
once and is stored only as a digest; fulfillment returns the exact signed
envelope bytes and never advances a lineage revision.

An Offer references an immutable policy id, not a serialized provider object
and not arbitrary Permit JSON supplied by the client. Policy configuration is
versioned and reviewed with code. A rights change creates a new policy id and
audit version; delayed work never resolves a mutable "latest" policy.

`commerce/permit` is the explicit server-side mapping boundary. Its smart
constructors validate grants, constraints, subject type, and complete snapshots
through the published `permit/issuer` package. The default `commerce` facade
does not import Permit.

The policy catalog contains active Offers plus retired definitions still needed
by retained journal, outbox, or lineage records. Removing an Offer from checkout
does not remove its definition. A deliberate deletion leaves an id tombstone
and fails with `offer-deleted`; a never-known id fails with `unknown-offer`.

## Purchase

A first successful purchase creates revision 0 with a stable internal subject
id and complete grants/constraints. The issuer worker derives deterministic
credential and entitlement lineage ids (`derive-entitlement-id`,
`derive-credential-id`), so reprocessing the same rights intent reconciles
to the recorded issuance result; the mapping itself is pure and byte stable
for identical inputs.

## Renewal and plan change

Renewal, upgrade, downgrade, seat change, and bundle change issue a complete new
revision in the same entitlement lineage. Commerce does not patch an old signed
credential.

## Refund and chargeback

A `withdraw` intent records commercial evidence; it does not claim impossible
offline revocation. The initial one-time policy implements one explicit
response: issue the next complete revision with `use_expires_at` equal to its
`issued_at`. Its use window ends at issuance, so it is expired afterward; an
older offline credential remains usable until another product mechanism can
reach it.

Future products may deliberately choose another honest response:

- accept the risk for a low-value perpetual offline purchase;
- require a short activation lease during the refund window;
- issue a newer restricted/expired revision to connected clients;
- distribute signed revocation state when supported;
- suspend future hosted service while leaving promised offline rights intact.

The operator UI and customer communication must describe the actual mechanism,
not the desired outcome.

## Snapshot request

`prepare-permit-snapshot` accepts a reviewed catalog, a `rights-intent`, issuer,
credential id, entitlement id, issuance time, and—only for withdrawal—the
previous complete entitlement snapshot. It returns policy id/version, action,
source idempotency key, the complete validated Permit payload, and the exact
serialized bytes. Both are deeply immutable copies. A later signer signs those
bytes; it never reconstructs JSON.

Grant rejects a previous lineage. Withdrawal requires one and verifies its
issuer, entitlement id, subject type/id, entitlement credential type, and grant
set against the pinned Offer policy before advancing the revision.

SQLite schema v3 reserves append-only lineage roots and contiguous revision
evidence, including the exact unsigned payload bytes and pinned policy
version; schema v4 adds the issued-credential record and one-time claim. `storage-complete-issuance-work!` is the only writer: it appends
the lineage root plus revision zero, or exactly one successor, inside the
same short transaction that completes the claimed issuance-outbox row, and
reconciles an already-recorded completion to the same revision. This module
itself does not claim outbox work, allocate ids, persist lineage, load a
key, call `issue-credential`, or deliver a claim.

## Trust domains

Permit credential-signing keys are distinct from:

- provider API/webhook secrets;
- Commerce claim-token secrets;
- update manifest/artifact keys;
- OS code-signing identities;
- database encryption and backup keys.

Production signing belongs behind an explicit issuer adapter and secret store.
The default Commerce facade never imports `permit/issuer`.


## Prepaid calendar-month initial grants

An opt-in constraints policy `#:use-duration-months` derives an initial grant's
`use_expires_at` from the order's authenticated `paid-at`, adding UTC calendar
months, clamping to the destination month's last day and preserving time of day.
A delayed issuer does not start a new service period. Fixed `#:use-expires-at`
and this duration are mutually exclusive. Missing paid evidence refuses with
`order-paid-evidence-required`; out-of-range dates refuse before signing.
The duration is Commerce policy metadata, never a new Permit protocol field.

This narrow policy does not admit repeat one-time purchases into an existing
lineage, allocate paid periods, isolate refunds across orders, or enable
checkout. Existing lineage rejection and successor rules remain in force.
Products must pass those separate gates before selling prepaid hosted service.
