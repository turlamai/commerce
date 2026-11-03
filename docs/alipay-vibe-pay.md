# Alipay Vibe Pay Basic Collection: implementation and deployment

- Provider: `alipay`
- Status: **protocol-core candidate only**; not merchant-admitted, not a production checkout
- Initial use case: **CNY one-time desktop/web purchases** opening the browser.
- References: [Vibe Pay](https://aipay.alipay.com/products/vibe-pay),
  [web integration guide](https://aipay.alipay.com/docs/vibe-pay/ai-web-app-payment-qianyi/ai-web-app-payment-integration-guide.html),
  [ADR-0019](decisions/0019-provider-admission.md),
  [Commerce #23](https://github.com/turlamai/commerce/issues/23).

## Implemented bounded slice

The Racket implementation now has separate modules for signed protocol
primitives (`commerce/alipay`), a bounded HTTPS order-query client
(`commerce/alipay/client`), and a journal-backed HTTP callback edge
(`commerce/alipay/server`). The edge does not carry Permit signer keys.
All modules remain **unapproved for real merchant use until CI and admission**.

1. Build server-priced signed `alipay.trade.page.pay` gateway fields with
   `make-alipay-page-pay-parameters`: exact fen-based `total_amount`,
   immutable `out_trade_no`, HTTPS callback addresses, RSA2 signing using
   an operator-held merchant private key. **This only returns signed fields;
   it does not submit a gateway request or create a remote order.**
2. Parse bounded HTTP form bytes with `parse-alipay-form` into a
   **duplicate-preserving decoded field association list**. Reject
   duplicate field names, missing signature, non-RSA2 mode and invalid RSA2
   signature. Build the ordered `key=value&...` signing representation
   excluding `sign` and `sign_type`. Verify using the pinned Alipay public
   key; do not use the merchant public key to verify callbacks.
3. Convert CNY decimal to exact fen, rejecting float, exponent, ambiguous
   precision and noncanonical inputs. Do not round silently.
4. A signed `alipay.trade.query` request is sent through the bounded,
   fixed-host HTTPS client. Its response signature is checked against the
   exact raw JSON response-node bytes, not a reserialized hash; the
   authenticated order facts have no publicly exported constructor.
   The response must match the durable checkout binding for merchant,
   transaction, currency and amount.
5. Only `TRADE_SUCCESS` matching all three sources can create a canonical
   `payment-succeeded` fact. The HTTP edge reads the immutable SQLite
   binding, verifies callback and query, writes the raw event to the existing
   Commerce journal and replies with exact plain-text `success` only after
   that transaction commits. A signed GMT+8 payment timestamp keeps replays
   deterministic.
   All other states reject. Never award rights on the browser `return_url`.
6. Every signed fixture uses synthetic IDs and a temporary RSA private key
   **not committed** to Git.

## Not yet implemented (must remain disabled for live use)

- A public, authenticated product checkout API: the current trusted
  `examples/alipay-checkout.rkt` generates a random `out_trade_no`,
  durably binds it before signing a browser-submittable HTML form, but
  now refuses to create an order unless a **private, time-limited**
  ADR-0019 admission record exactly matches merchant, environment, Offer,
  product, payment method, CNY amount and permitted transaction type.
  This is an operator gate, **not** evidence that a merchant was approved.
  A public product checkout still needs authenticated server-side identity.
- Certificate-mode and key-rotation support: currently **RSA2 public-key
  mode only** with explicit sandbox and production isolation.
- Automated missed-webhook reconciliation, timed worker retry schedules,
  deployed reverse-proxy protection and real environment traffic proof.
  `examples/alipay-service.rkt` provides the loopback-only HTTP process;
  it is not a production deployment playbook by itself.
- `commerce/alipay/refund` implements signed full-amount refund-request
  parameters and independently signed refund-query verification. On explicit
  `REFUND_SUCCESS`, matching order, request ID, and original amount, the
  trusted operator may call `journal-alipay-full-refund!` to durably record
  the exact signed query bytes. Stable event IDs make identical replay
  idempotent; the ordinary projector/outbox subsequently handles withdrawal.
  **This does not initiate a provider refund or expose a public refund endpoint.**
  The operator-authorized network call, durable request-state machine, retry
  schedule, and verified live merchant flows are still missing. `code=10000`
  alone never proves refund success; absent signed `gmt_refund_pay` cannot
  be replaced with a local receive timestamp.
- Partial refunds and the cumulative refund ledger are **not supported**:
  current Commerce's binary refunded projection cannot faithfully represent
  them. Any partial-refund request is rejected. Do not issue a Permit
  withdrawal from a pending, failed, or partial refund.
- Full end-to-end production integration, an operator refund execution
  runbook, and accepted merchant credential evidence. Confirmed payments
  must come from the authenticated active-query and callback boundary;
  never construct trusted payment facts from browser requests or callbacks
  alone.

## Time and replay identity

Alipay timestamps such as `gmt_payment`, `gmt_refund_pay` and the
gateway request `timestamp` use **UTC+08:00**, not the server's
configured local time zone. All three now share a Gregorian civil-time
conversion independent of host time zone or daylight saving settings.
Malformed/nonexistent dates fail closed, and an authenticated duplicate
notification retains the same canonical event occurrence time on
Windows, macOS and Linux.

## Threat and readiness checks

Verify current merchant/app eligibility and capability matrix (CNY,
one-time website payment, geographic scope, product category, refund fees,
payout and settlement) per ADR-0019 before enabling a live checkout. Payment
receipt, settled balance and bank payout are different financial facts.

Verify signed callback against `app_id`, `seller_id`, `out_trade_no`,
`trade_no`, exact `total_amount`, `trade_status`, and the independently
authenticated order query. Keep payment and Permit signing keys isolated.
Always journal authenticated raw input before the provider acknowledgement;
do not perform slow entitlement signing on the callback thread.

Negative cases: signature tamper, duplicate params, seller/app mismatch,
amount mismatch, replayed `notify_id`, delayed delivery, query timeout,
`WAIT_BUYER_PAY`, partial/full refund, test/production confusion, and
manual operator retry. Do not count source-level tests as a live payment.

### Useful commands once the PR is checked out

```sh
raco pkg install --auto --no-docs --name commerce --link
raco test commerce-test/alipay-test.rkt commerce-test/alipay-refund-test.rkt
raco test -p commerce
raco setup --check-pkg-deps commerce
```

The signed synthetic fixture checks the verification boundary, not actual
Alipay merchant authorization. Issues [#5](https://github.com/turlamai/commerce/issues/5),
[#10](https://github.com/turlamai/commerce/issues/10) and
[#4](https://github.com/turlamai/commerce/issues/4) remain independent
production release gates.

## Local checkout and callback drill (no real account needed for code tests)

The service uses only your **Alipay merchant gateway signing key**, never
the Permit issuer signing key. Use the separately configured, approved
`ALIPAY_ENV`, `ALIPAY_APP_ID`, `ALIPAY_SELLER_ID`,
`ALIPAY_PRIVATE_KEY_PATH`, `ALIPAY_PUBLIC_KEY_PATH`,
`COMMERCE_DATABASE_PATH`, `COMMERCE_HTTP_PORT`,
`ALIPAY_NOTIFY_URL`, `ALIPAY_RETURN_URL` and
`COMMERCE_PROVIDER_ADMISSION_PATH`.
Use [the placeholder-only template](../deploy/alipay.env.example), never
commit populated secret files. The
[operator admission template](../deploy/alipay-admission.template.json)
intentionally contains missing references and invalid amounts/expiry; it
**cannot** authorize checkout unchanged. The operator must privately verify
merchant approval, supported methods, costs, settlement and the exact
reviewed Offer price before filling this deployment-owned record. A nonempty
reference is an audit pointer, not cryptographic approval evidence.

`commerce/admission` rejects missing/expired documents, duplicate JSON fields,
unrecognized keys, wrong merchant app/seller, environment, transaction,
product, Offer, currency, exact amount, unsupported Alipay contracts and
out-of-range values. Refusal occurs before any order ID or binding is minted.

The operator example (not a public price API) binds a **new random**
merchant order to product, Offer, opaque subject and exact CNY fen before
printing a signed, submit-by-button HTML checkout form:

```sh
racket examples/alipay-checkout.rkt taskly taskly-pro-lifetime subject-001 2900 'Taskly Pro' > checkout.html
racket examples/alipay-service.rkt
```

Serve the callback only through an externally trusted TLS reverse proxy at
`/webhooks/alipay`. Sandbox and production use distinct Alipay merchant
credentials. A browser return is display-only and cannot grant Permit rights.
Pending issued rights still flow via existing journal projector and separate
Permit issuer worker.

This is **not evidence that Alipay approved our product or that a live payment
worked**. Before connecting real accounts, approve the merchant account and
product category, confirm fees and refund rules, prove the whole CI matrix,
then run a documented sandbox payment, refund and replay drill with sensitive
fields redacted.
