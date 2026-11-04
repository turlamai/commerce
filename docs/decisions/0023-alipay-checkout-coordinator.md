# ADR-0023: trusted Alipay checkout coordination (development)

Publy needs a Commerce-owned checkout after authenticating its own account.
An endpoint that accepts a buyer-chosen price or subject would bind payment
to an untrusted identity. The initial slice is an in-process coordinator,
not an HTTP listener or a production checkout.

The caller supplies a trusted, already-authenticated service and subject,
an operator-owned Offer, a private provider-admission record and a request
identity. A server-owned scope callback must explicitly approve that exact
service, product, Offer and subject. The coordinator validates Alipay's CNY
one-time admission before creating a durable immutable checkout binding. A
separately provisioned, append-only SQLite claim pins service, merchant,
environment, subject, Offer/policy, amount and callback settings first. It
derives an opaque provider order ID from the framed service and request ID,
so retries recover the same binding; an existing binding with different
subject, merchant, environment, product, Offer or money is a conflict. Signed page-pay parameters are
generated only after the binding exists. Signing failure leaves a recoverable
binding and never indicates payment; retries use the same provider order.

This is not service authentication or replay protection. A future network
adapter must separately authenticate raw request bytes, enforce nonce and
scope policy, select Offer and price from trusted server configuration, and
control resource use. A browser return cannot establish payment. Webhook,
independent query, journal, issuer, refund and entitlement admission remain
separate boundaries. Merchant admission and live payment remain gated.

Claims and Commerce's ledger require coordinated backup and restore. A missing
claim store is an error; an existing ledger binding with a missing claim is
not re-enrolled automatically. Stop checkout and reconcile after uncertain
restore or data loss. SQLite file permissions and independent signer-intent
authorization remain required; an append-only trigger is not a boundary
against an attacker who controls the database file.
