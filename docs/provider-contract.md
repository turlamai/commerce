# Provider contract

Every provider adapter converts one external protocol into authenticated
canonical facts. It does not decide product rights.

## Adapter operations

An adapter may implement these capabilities independently:

- create a hosted checkout session for one configured Offer;
- authenticate and parse a webhook or signed receipt;
- actively fetch an order/payment by provider id;
- request a refund;
- inspect subscription state;
- map test-mode and live-mode identities without mixing them.

The initial Racket boundary is `provider-adapter` in `commerce/provider`:

```racket
(provider-adapter id create-checkout verify-webhook fetch-order)
```

Procedure signatures will graduate only with the first real adapter. Until
then, this struct records ownership and prevents network/provider code from
leaking into the pure core.

## Required webhook proof

Before calling `make-verified-payment-event`, an adapter must:

1. authenticate the exact raw request using the provider's documented scheme;
2. enforce body, header, and timestamp limits;
3. reject test/live environment confusion;
4. parse without discarding duplicate or security-critical fields;
5. map the provider product/price to a configured Offer;
6. resolve a stable internal subject id without using display email as identity;
7. represent money in exact minor units;
8. perform active order lookup when the provider contract or threat model
   requires it;
9. compute a SHA-256 digest of the authenticated raw representation;
10. emit one canonical event or a typed, operator-visible rejection.

## Delivery behavior

Providers may retry, duplicate, delay, or reorder notifications. Adapters must
not assume at-most-once or ordered delivery. The journal key is
`(provider, event-id)`; the projection key is `(provider, order-id)`.

Return the provider's required success acknowledgement only after durable
journal acceptance. Slow signing, email, or product delivery happens after the
request through the outbox.

The initial durable boundary is explicit:

```racket
(require commerce/journal
         commerce/storage
         commerce/storage/sqlite)

(define storage (open-sqlite-commerce-storage database-path))
(journal-accept! storage raw-request canonical-event
                 #:received-at receive-time)
```

`journal-accept!` recomputes the SHA-256 digest from the exact bytes. It returns
`accepted` only after the SQLite transaction commits, returns `replayed` for an
exact retry, and raises `event-conflict` for changed raw or canonical content.
Only `accepted` and `replayed` are acknowledgement outcomes.

Projection is deliberately after acknowledgement. A projector repeatedly calls
`storage-project-next!`; each successful transaction persists the current order,
any newly emitted issuance work, and the journal-sequence marker together.

## Reconciliation

Webhook delivery is not the only evidence path. Every production adapter with a
query API must support periodic reconciliation:

- fetch changed/succeeded/refunded orders for a bounded period;
- compare them with local journal/projections;
- ingest missing facts through the same canonical path;
- report mismatches without silently editing history.

## Admission

Fixtures and sandbox drills prove protocol conformance; they do not
prove merchant eligibility. A provider adapter may present a live
checkout only after its admission record is complete — approved account
scope, capability matrix, verified contract paths, separately staged
costs, and typed refusal behavior (ADR-0019). Offers outside the
admitted matrix are rejected before a checkout is presented: a checkout
a buyer cannot pay must never be offered, and nothing is repriced,
converted, or split to fit. Current status: Pancake and ZPAY are not
admitted; no approved merchant account exists.

## Alipay Vibe Pay Basic Collection (candidate)

The initial **server-side Racket** `commerce/alipay` module validates
RSA2-signed notifications against durable merchant order bindings and
independently authenticated active query facts, emitting one canonical
one-time payment event on a complete match. It is not yet an HTTP,
checkout, refund, or approved-merchant adapter. See the
[Alipay integration boundary and release gate](alipay-vibe-pay.md);
keep every unimplemented production capability disabled.

## Alipay operator refund lifecycle

The opt-in [ADR-0022](decisions/0022-alipay-refund-operations.md) operation
ledger refuses a second full-refund dispatch for an uncertain merchant order.
Only the existing independently authenticated signed refund query can complete
an operation and journal a withdrawal. This is an operator-side library, not a
live refund service or proof of approved merchant status.

## Provider-specific notes

Pancake is the first production adapter because it supports individual
developers, hosted checkout, one-time products, subscriptions, refunds, and a
Merchant-of-Record workflow. `commerce/pancake` authenticates its webhook
envelope and actively verifies one-time orders. The `X-Waffo-Signature` value
contains one millisecond timestamp `t` and one base64 signature `v1`;
RSA-SHA256/PKCS#1 v1.5 signs the ASCII timestamp, one period byte, and the exact
request body. Verification requires an explicit test/production environment,
uses separate public keys, accepts at most 45 minutes of retry age and one
minute of future skew, rejects duplicate top-level JSON fields, and verifies
payload `mode` after cryptographic authentication.

The active read is one signed merchant `POST` to
`https://api.waffo.ai/v1/graphql`; test and production share this endpoint.
Commerce sends no idempotency key, follows no redirect, and makes no hidden
retry. A timeout, HTTP 408/429, or 5xx response is a retryable
`pancake-order-unavailable` failure for the durable worker. Other authentication,
query, not-found, malformed-response, and semantic failures are separately
typed and redacted.

The query checks order id, `completed` status, `testMode`, store id,
`orderMerchantExternalId`, one-time product id, order/payment currencies, the
webhook payment id and its `succeeded` status, and the payment snapshot total.
The total is converted from a strict decimal string using the configured
currency exponent and compared as exact minor units. The external id must name
a server-side checkout binding for one Offer and stable subject; it is not the
subject itself. Email and provider customer identities never establish local
authorization. Only this complete proof becomes a canonical `payment-event`.

Committed fixtures and generated disposable keys prove protocol conformance;
live sandbox evidence remains a later M1 gate.

ZPAY is planned as a separate one-time-payment capability. Its documented
duplicate callbacks, MD5 signing, exact amount checks, and recommended active
order query make the journal/reconciliation boundary mandatory. Commerce will
not model ZPAY as a recurring provider unless the live provider contract gains
that capability.

