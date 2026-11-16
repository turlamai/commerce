# ADR-0025: Reconcile a lost Alipay notification with two signed proofs

Status: accepted for the explicit server-side integration candidate; live
merchant admission and unattended product deployment remain separate gates.

## Failure and invariant

A successful payment can outlive a missing notification. A browser redirect,
client boolean, unsigned query result, or manual database update cannot grant
rights. Recovery must preserve provider authentication, the immutable checkout
subject/Offer/amount, stable payment time, offline issuer re-verification and
one grant per one-time order.

## Decision

An operator/product server may explicitly submit the original RSA2-signed
`alipay.trade.page.pay.return` form and independently fetch a fresh signed
`alipay.trade.query` response. Verify both signatures with the deployment-held
Alipay public key. The signed return must bind expected app, seller, order,
trade and exact amount; the signed query must match order, trade and amount,
report `TRADE_SUCCESS`, and supply the payment time in `send_pay_date`.
Return timestamps and local receipt times never select the paid window.

Only the durable checkout binding selects subject and Offer. Journal the exact
return bytes and exact signed query evidence together under `return-query:`
plus the signed trade id. The issuer repeats both signature checks, native
field comparisons, payment-time derivation, catalog and durable binding checks
before signing. The issuer must independently configure trusted app and seller
identifiers; it never derives its expected merchant from the submitted proof.
This path adds no signing authority to an HTTP edge.

A retry re-authenticates new proofs and the original stored proofs. It reuses
the original journal row only when all canonical event fields agree. Provider
response formatting changes cannot create a second grant. A later normal
notification may add a separate authenticated journal fact; the existing
one-time projection emits no second grant for an already paid order.

## Boundaries

This is an explicit reconciliation API, not a public unauthenticated endpoint,
a replacement for notifications, a merchant approval, or evidence that a
notification arrived. It performs no payment/refund request. A product owns
capturing the original signed return, trusted merchant configuration, account
recovery and authenticated invocation. When the signed return is missing,
forged or mismatched, this path refuses; query-only recovery is not admitted.

Existing notification evidence and refund evidence keep their existing paths.
No schema migration is needed: supplementary signed query bytes use the
existing immutable journal evidence column. Keep these raw proofs private.
