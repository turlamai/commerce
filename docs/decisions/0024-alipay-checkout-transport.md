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
