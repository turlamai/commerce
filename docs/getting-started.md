# Getting started

**English** · [简体中文](getting-started.zh-CN.md)

This guide takes a new contributor from an empty Racket installation to one
audited purchase transition. It uses the mock boundary deliberately: no account,
secret, network access, or real payment is required.

## 1. Requirements

- Racket CS 9.0 or newer
- Git

## 2. Install a linked checkout

```bash
git clone https://github.com/turlamai/commerce.git
cd commerce
raco pkg install --auto --no-docs --name commerce --link "$PWD"
```

The package contains multiple collections. Product-safe code starts with:

```racket
(require commerce)
```

Provider adapters explicitly add:

```racket
(require commerce/provider)
```

Services that durably accept authenticated events explicitly add:

```racket
(require commerce/journal
         commerce/storage
         commerce/storage/sqlite)
```

The Pancake edge authenticates exact request bytes in an explicit environment:

```racket
(require commerce/pancake)

(define verified
  (verify-pancake-webhook raw-body signature-header
                          #:environment 'test))
```

`verified` is provider-native evidence, not yet a canonical payment event. A
service next supplies the server-side checkout binding and merchant credential:

```racket
(define merchant
  (make-pancake-merchant-client
   "MER_yourMerchant"
   (getenv "PANCAKE_MERCHANT_PRIVATE_KEY")
   #:environment 'test))

(define binding
  (pancake-order-binding
   "random-checkout-reference" ; stored when checkout is created
   "PROD_providerProduct"
   "taskly-pro-lifetime"
   "opaque-stable-subject"
   (money "USD" 2900)
   2))                         ; configured ISO 4217 exponent

(define canonical-event
  (verify-pancake-onetime-order merchant verified binding))
```

The active proof requires a completed order and succeeded webhook payment whose
environment, store, external reference, product, currency, and exact amount all
match. The private key is deployment-injected and never committed. The external
reference resolves to the Offer and stable subject in server storage; it is not
an email, subject id, or client-provided claim.

Durable acceptance and projection are intentionally two operations:

```racket
(define storage (open-sqlite-commerce-storage database-path))

;; Return the provider acknowledgement after this commit succeeds.
(journal-accept! storage raw-body canonical-event
                 #:received-at receive-time)

;; Run outside the webhook request. #f means there is no pending sequence.
(let project-pending ()
  (when (storage-project-next! storage #:processed-at (current-seconds))
    (project-pending)))
```

Each projector call commits the order, newly emitted issuance work, and source
sequence marker together. The outbox row remains `pending`; this release does
not call Permit or deliver a credential.

The separate Permit adapter prepares, but does not sign, complete rights
snapshots:

```racket
(require commerce/permit)

(define pro-policy
  (make-permit-entitlement-policy
   "taskly-pro-v1" 1
   #:subject-type 'person
   #:grants
   (list (make-permit-grant-policy
          #:products '("taskly")
          #:edition "pro"))))

(define policy-catalog
  (make-permit-policy-catalog (list configured-offer)
                              (list pro-policy)))

(define snapshot-request
  (prepare-permit-snapshot
   policy-catalog grant-intent
   #:issuer "com.example"
   #:credential-id stable-credential-id
   #:entitlement-id stable-entitlement-id
   #:issued-at "2026-10-17T03:00:00Z"))
```

The Offer pins the immutable policy id. The result contains a Permit-validated
payload and the exact bytes a future signer must consume. A withdrawal also
requires the previous complete snapshot; no private key or signer is used here.

## 3. Run the first purchase

```bash
racket examples/first-purchase.rkt
```

The walkthrough constructs a payment event as though a mock adapter had already
authenticated it, then applies it to an immutable state. One `grant` rights
intent is emitted. Replaying the same provider event is acknowledged without
emitting a second intent.

## 4. Read the test before changing behavior

```bash
raco test commerce-test/core-test.rkt commerce-test/journal-test.rkt \
  commerce-test/storage-test.rkt commerce-test/pancake-test.rkt \
  commerce-test/permit-test.rkt
```

The tests show the intended answers to the first difficult questions:

- What happens when a provider retries the same webhook?
- What happens when an event id is reused with different content?
- What happens when a refund notification arrives before the payment event?
- What prevents two success notifications from granting twice?
- What happens when amount or offer identity changes for the same order?
- What proves acknowledgement survives a service restart?
- What database row is emitted, and can ordinary SQL mutate it?
- What exact Pancake bytes are signed, and how do stale, cross-environment, or
  ambiguous signed requests fail?
- What exact merchant request is signed, and how does every active order
  substitution fail before a canonical event exists?
- Which database rows prove that order projection and issuance work committed
  together, and what remains after an injected crash?
- How do policy version pinning, deleted Offers, invalid policy, and mismatched
  entitlement lineage fail before a signer sees bytes?

## 5. Understand the boundary

Read these in order:

1. [Concepts](concepts.md)
2. [Architecture](architecture.md)
3. [Provider contract](provider-contract.md)
4. [Permit integration](permit-integration.md)
5. [Security](security.md)

Do not begin a real provider adapter from its happy-path SDK example. Capture
its authentication scheme, retry behavior, query API, refund semantics, test
mode, and fixture evidence in the provider contract first.

## 6. Run the full gate

```bash
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/storage.rkt commerce/storage/sqlite.rkt commerce/pancake.rkt \
  commerce/permit.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

The first production provider is Pancake. Signature conformance and active
one-time-order verification plus durable journal/projection/outbox processing,
Permit snapshot policy mapping, lease-guarded issuance, deterministic signing,
and one-time claim delivery are implemented. Refund/operator replay tooling
and live sandbox evidence remain separate M1 gates in
[ROADMAP.md](../ROADMAP.md).


[Upgrades, maturity and support](USING.md).
