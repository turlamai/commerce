# ADR-0024: authenticated checkout transport (development)

The checkout coordinator receives only trusted values. A product-service
transport must authenticate the exact request method, path and body before
looking up an Offer or creating a claim. The authenticated service must be
authorized for the exact issuer, account subject, Offer and product, and a
durable nonce claim must prevent replay. The service request ID is distinct
from its fresh transport nonce: a retry uses the same request ID and a new
nonce, and therefore recovers the same Commerce order.

The request carries identifiers only. Price, title, merchant, gateway,
callback addresses and admission are selected from trusted server-side
configuration; a caller cannot supply them. The response contains a signed
Alipay request and a Commerce order reference, never a payment success or
Permit right. Alipay callback/query verification and entitlement issuance
remain separate. Unknown fields, changed scope, bad MAC, replay, missing
catalog entry, unavailable state and invalid admission fail closed.

This slice defines a development-only handler and opt-in loopback listener
with injected trusted policy and no public deployment. TLS, body limits, key rotation,
secure account-to-subject provisioning, signer isolation, coordinated backup,
refund recovery, merchant admission and real transaction proof remain gates.

## Replay state, recovery and launch gates

The request MAC and scope verifier `commerce/hosted-auth` must use
`commerce/hosted-replay/sqlite` (or an equivalent atomic durable claim store)
for `#:claim-once!` when an operator deploys this boundary. Provision the
nonce database **before** enabling the listener; the runtime claimer must
open an existing database in read/write mode and fail closed if it disappears.
Never replace this with an in-memory hash in production. A retry after an
unknown HTTP result uses the **same Commerce request ID** and a **fresh
transport nonce**; this reuses the existing checkout binding and does not
claim that payment occurred.

Back up and restore the nonce store, checkout-claim store and Commerce ledger
as one reviewed recovery unit. Losing any component or encountering an
unreconciled mismatch requires disabling checkout and operator review; do not
silently initialize new replay or checkout-claim state during service startup.
The SQLite stores and signing keys need independent OS permissions. A
successful unit test, simulated loopback response or green CI matrix does not
satisfy human merchant approval, payment verification, signer isolation,
payout/settlement or the release gates in `docs/release-checklist.md`.
One-time prepaid entitlement periods **do not renew automatically**.
