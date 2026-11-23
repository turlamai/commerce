# ADR-0027: NowPay Direct duration authorization

- Status: Accepted for implementation; not a deployed acceptance claim
- Date: 2026-11-23
- Owner request: NowPay Direct monthly product integration; issues #67 and #69

## Authority and bindings

NowPay Direct is a provider-specific current-access authority, not the Basic Collection payment-event adapter. Its RSA2-authenticated `charge.query` establishes the configured product and purchasable SKU; `purchase.consult` establishes current application-user rights and the provider's Asia/Shanghai `[valid_from, valid_until)` interval. SDK camelCase names map to snake_case `biz_content` fields. Prices are strict decimal CNY converted to integer fen. No ALLOW result becomes a fabricated paid order, revenue row or canonical payment event.

The merchant app and external product are pinned in restricted service configuration. The stable application user id supplies `external_buyer_id`; display email, payer identity and browser parameters do not. Provider response bodies do not echo all request bindings, so their signatures alone are not portable proof of the beneficiary. Only a trusted issuer's own fresh bounded HTTPS request may establish that request/response association. The issuer never accepts a caller-supplied provider response as grant evidence.

## Process boundary

Production installation uses released copied packages and persistent systemd units. A dedicated unprivileged issuer runs a one-request standard-input/output CLI behind a local systemd socket. The socket ACL permits only the product service and issuer; there is no public HTTP listener or Permit key in the public edge. Merchant and Permit private keys remain separate files. Issuer state is writable only by the issuer, not by the public product process. Other products use independent OS users, configuration, sockets and databases.

For authorization, the product generates an unpredictable nonce and supplies its authenticated application user id. The issuer actively queries the configured provider product for that user, authenticates exact response bytes, strictly parses duplicates/critical values, checks current provider time and signs a Permit entitlement with pinned product/edition and platform expiry. A namespaced signed extension binds the request nonce, service, provider product, authoritative period and a short freshness deadline. The product independently verifies Permit and every binding before admission and at queued execution. Each response belongs to exactly one pending local request; cached credentials, browser returns and forged local paid flags cannot grant new work.

Issuer-owned SQLite state preserves monotonic entitlement revisions and private request/response audit digests across restarts. It is separate from the canonical payment journal. Concurrent authorization must serialize snapshot publication; errors and unknown provider outcomes cannot publish a grant. Authorization evidence does not report whether the provider settled money.

## Purchasing and refusal

The initial supported offer is exactly one reviewed MONTH duration SKU and configured integer price. New purchasing requires matching billing mode, unique SKU/price/period and ENABLED capability, plus PURCHASE_REQUIRED from a fresh consultation. ALLOW never offers another active-period purchase. DENY, signature/transport/schema failures and unexpected configuration fail closed. A disabled new-purchase capability does not revoke independently valid existing rights.

Return URLs are static trusted HTTPS configuration and only trigger another consultation. The gateway query uses RSA2, fixed production HTTPS, bounded body/time limits, no redirect and no hidden retry. Full raw responses and purchase tokens are not ordinary logs. A refund is reflected by a subsequent current provider decision; this module does not claim support for a refund-write API or initiate one. Provider-specific live purchase, refund, expiry/recovery, merchant limits and settlement acceptance remain separate, explicitly authorized gates.
