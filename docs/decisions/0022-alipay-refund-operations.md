# ADR-0022: Alipay full-refund operation state and unknown outcomes

- Status: Accepted for **operator-side implementation**, not live payment approval
- Scope: [Commerce #23](https://github.com/turlamai/commerce/issues/23) and [#27](https://github.com/turlamai/commerce/issues/27)
- Related: [ADR-0019](0019-provider-admission.md), [provider contract](../provider-contract.md)

## Failure mode

A full-refund HTTP call may reach Alipay even when the caller times out
or crashes before it receives a response. Re-sending it with a new request ID
could cause a second money movement. A successful HTTP response or a gateway
business code is not a signed refund fact and may not withdraw Permit rights.

## Decision

Commerce's explicit Alipay refund-operations module is an **operator-only**
API with a separately provisioned, durable SQLite operation ledger.
No background scheduler, public endpoint or automatic network transport is added.

1. An operator must be authorized by a deployment callback. The code verifies
   a paid/unrefunded Commerce order against its append-only checkout binding,
   subject, Offer and exact CNY amount. A single environment, app-id and order
   can have only one durable refund request; another request ID fails.
2. Request records are persisted as **requested** before any remote call.
   Exact retries are idempotent; conflicting identities fail closed.
3. The dispatch operation atomically records **unknown** *before* calling an
   operator-supplied, money-moving send-once callback. Any success, timeout,
   crash or exception leaves unknown. A second dispatch fails, even after
   restart. Never auto-retry unknown outcomes.
4. Only reconciliation may move unknown to **confirmed**. It obtains exact,
   signed refund-query bytes from a read-only callback; the existing protocol
   verifier requires REFUND_SUCCESS, matching order, request ID and **full**
   CNY amount. Journal acceptance commits before the operation becomes
   confirmed. A crash between these commits is safe: signed evidence replays.
5. Confirmed means **signed refund evidence journaled**, **not** projection
   caught up, offline Permit revocation, settled funds, or go-live approval.

The ledger intentionally does **not** infer a terminal failed state from
untrusted HTTP responses. The operator must resolve a truly unknown outcome
with provider-side evidence; there is no API to delete/reissue a request after
uncertainty. Partial refunds remain refused.

## Deployment / recovery

Provision a separate, access-restricted file once using
initialize-sqlite-alipay-refund-operations!, never initialize an empty
store on restart. Use separate sandbox/production storage and identities.
Restrict access to the operator process; the HTTP edge and signing worker
do not need the refund ledger or merchant signing keys. Back it up with the
payment journal.

The caller explicitly supplies a trusted operator-identity authorizer
and a signing/HTTP sender. This library does not invent an approved merchant,
generate production keys, or initiate refunds by itself.
A scheduled reconciliation operator should poll signed queries for unknown
operations **without repeating the money-moving call**. Real sandbox/live
proof, key rotation, fees and #4/#5 acceptance remain NO-GO.
