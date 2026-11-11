# Examples

Every example is a copyable newcomer path over real module boundaries. They
are referenced from the README, the runbook, and the deploy guide, and CI
executes `first-purchase.rkt` on every change.

| Example | What it demonstrates | Run |
| --- | --- | --- |
| [`first-purchase.rkt`](first-purchase.rkt) | The smallest path: one verified provider event ingested into the pure facade, producing one order projection and one rights intent. | `racket examples/first-purchase.rkt` |
| [`full-journey.rkt`](full-journey.rkt) | The complete end-to-end journey: authenticated webhook, actively verified one-time order, durable journal and projection, deterministic Permit issuance, and one-time claim fulfillment — with run-time keys, so it is reproducible everywhere. | `racket examples/full-journey.rkt` |
| [`service.rkt`](service.rkt) | Role-selectable service assembly (`COMMERCE_ROLE=edge|issuer|all`): the HTTP edge and the signing/projector worker as separate processes over one SQLite store. Run only after reading [docs/runbook.md](../docs/runbook.md) and [deploy/README.md](../deploy/README.md). | `racket examples/service.rkt` |
| [`gptp-studio-updates-window.rkt`](gptp-studio-updates-window.rkt) | gptp-studio — the family's first paid product — as a worked offer: a perpetual Pro edition whose updates window comes from one year of paid evidence. | `racket examples/gptp-studio-updates-window.rkt` |
| [`alipay-checkout.rkt`](alipay-checkout.rkt) | Trusted operator example: a durable, server-priced checkout binding before a signed Alipay page-pay form. No browser-submitted price or subject identity is accepted. Note: this example currently imports `commerce/private/alipay-time`, an implementation-only helper; it is an integration candidate, not a stable copy path. | `racket examples/alipay-checkout.rkt` |
| [`alipay-service.rkt`](alipay-service.rkt) | Example edge process for an approved Alipay merchant account, loopback-only behind a TLS reverse proxy. Never co-locate a Permit issuer private key in this process. | `racket examples/alipay-service.rkt` |
| [`hosted-proof-service.rkt`](hosted-proof-service.rkt) | Local-only operator entrypoint for the hosted Permit proof listener (development stage; provision the nonce DB first per [docs/hosted-proof-http.md](../docs/hosted-proof-http.md)). | `racket examples/hosted-proof-service.rkt` |

None of these examples carries real channel credentials, Permit signing keys,
or demo paid offers. For live provider work, follow
[docs/runbook.md](../docs/runbook.md) and the deployment guide.
