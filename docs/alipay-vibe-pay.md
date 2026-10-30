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
  deliberately accepts prices only from the **operator**, not the public.
  Production callers need reviewed server-side Offer pricing and identity.
- Certificate-mode and key-rotation support: currently **RSA2 public-key
  mode only** with explicit sandbox and production isolation.
- Automated missed-webhook reconciliation, timed worker retry schedules,
  deployed reverse-proxy protection and real environment traffic proof.
  `examples/alipay-service.rkt` provides the loopback-only HTTP process;
  it is not a production deployment playbook by itself.
- A full-refund request and authenticated confirmation primitive now live
  in `commerce/alipay/refund`: exact original amount, caller-supplied
  stable `out_request_no`, RSA2 request signing, and signed
  `alipay.trade.fastpay.refund.query` status/amount verification.
  **No refund endpoint or provider refund-event journal writer is enabled**.
  We deliberately require `REFUND_SUCCESS` rather than mistaking
  `code=10000` for refund success.
- Partial refunds and the cumulative refund ledger are **not supported**:
  current Commerce's binary refunded projection cannot faithfully represent
  them. Any partial-refund request is rejected. Do not issue a Permit
  withdrawal from a pending, failed, or partial refund.
- Full end-to-end integration, operator runbook and accepted merchant
  credential evidence. The `alipay-confirmed-order` struct is explicitly
  a **trusted-service input** until a real signed query adapter enforces it;
  do not build it from user requests, JSON, test fixtures, or a callback.

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
raco test commerce-test/alipay-test.rkt
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
`ALIPAY_NOTIFY_URL` and `ALIPAY_RETURN_URL`.
Use [the placeholder-only template](../deploy/alipay.env.example), never
commit populated secret files.

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
