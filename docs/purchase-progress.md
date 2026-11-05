# Product-scoped purchase progress (trusted server-side read)

Commerce provides an opt-in, provider-neutral server primitive at
`commerce/purchase-progress`. It is for an **authenticated product backend**,
not for a public browser or desktop client.

The product must authenticate its account and map it to a stable Commerce
subject. The required five-argument authorization callback must return literal
`#t` for the provider, order, product, Offer and subject tuple. It runs
**before the first database lookup**. The stored append-only checkout binding
must independently match all five identifiers or the read fails closed.
Never derive an account, amount or paid flag from a browser redirect, email,
untrusted claim token or provider customer identity.

## Returned states

Only one field is returned: `status`. The states are:

| Status | Meaning | Grants an entitlement? |
| --- | --- | --- |
| `unknown-checkout` | No stored checkout binding exists | No |
| `awaiting-payment` | Bound checkout exists without accepted payment evidence | No |
| `payment-processing` | Evidence is accepted but projection or provider outcome is not complete | No |
| `issuance-pending` | Paid projection exists; no completed signed credential evidence yet | No |
| `credential-recorded` | A grant issuance has signed credential evidence recorded | **Still no** |
| `refund-pending` | A durable refund event is not yet reconciled to issuance | No |
| `refunded` | The order projection records the refund | No |
| `unavailable` | Read or projection coherence cannot be trusted | No |

There are no raw provider events, payment credentials, emails, claim tokens,
issuer secrets, prices, or customer details in this response. Product UI may
show pending/recovery guidance, but may **never** unlock a feature based on
this status, even when it says `credential-recorded`. Only locally verified
Permit credentials grant product rights.

## Recovery responsibilities

A missing browser success return is harmless: query the same logical order,
do not create a second checkout by default. A delayed webhook yields an
ordinary pending state. Once the issuer records a signed credential, the
existing one-time claim portal can deliver it; an expired/lost claim is
recovered through the existing authenticated operator reissue path without
creating another lineage revision. Commerce cannot know whether a product
has locally imported its credential, so `imported` is **not** invented
as a server status. A product keeps that final state.

This slice exposes no public HTTP endpoint. Each product backend owns its
authentication, rate limiting, customer recovery and user-facing copy.
Production go-live remains blocked by real merchant #5 and #4 evidence.
