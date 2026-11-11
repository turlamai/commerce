#lang scribble/manual

@(require (for-label racket/base
                     json
                     commerce
                     commerce/provider
                     commerce/journal
                     commerce/storage
                     commerce/storage/sqlite
                     commerce/pancake
                     commerce/permit
                     commerce/issuer
                     commerce/operator
                     commerce/log
                     commerce/health
                     commerce/server
                     commerce/reconcile
                     commerce/evidence
                     commerce/admission
                     commerce/backup
                     commerce/retention
                     commerce/purchase-progress
                     commerce/checkout-http))

@title[#:tag "commerce"]{Commerce: Provider-Neutral Commerce Orchestration}
@author{TuringLambdaAI}

@defmodule[commerce]

Commerce is a provider-neutral commercial management core: authenticated
payment facts enter, deterministic order projections and rights intents leave.
It orchestrates payment providers and a Permit issuer without moving payment or
authorization policy into Rivet, Glaze, Keel, or product clients.

The default module is pure. Provider adapters explicitly require
@filepath{commerce/provider.rkt} to construct verified canonical events after
their native authentication and semantic checks. Server-side capabilities are
always explicit modules: journaling, projection, Permit policy mapping, the
issuance worker, the HTTP edge, and operator tooling are never re-exported by
the default facade.

@section{Core values and the pure facade}

The @racket[(require commerce)] facade is pure and product-safe: values,
deterministic projections, and the typed exception. It contains no network,
storage, or signing.

@defstruct*[money ([currency string?] [minor-units exact-nonnegative-integer?])]{
Represents money exactly in the currency's smallest configured unit. Currency
is an uppercase three-letter ISO 4217 code. Floating-point amounts are
rejected by the constructor guard.}

@defstruct*[offer ([id string?]
                   [product-id string?]
                   [kind (or/c 'one-time 'subscription)]
                   [price money?]
                   [entitlement-policy-id string?])]{
Describes one stable thing a customer may buy. Identifiers are lowercase
kebab-case. Provider product and price identifiers are mappings owned by the
service and are not part of this value.}

@defstruct*[payment-event ([provider string?]
                           [event-id string?]
                           [payload-digest string?]
                           [kind symbol?]
                           [order-id string?]
                           [offer-id string?]
                           [subject-id string?]
                           [amount money?]
                           [occurred-at exact-nonnegative-integer?]
                           [paid-through (or/c exact-nonnegative-integer? #f)])]{
One authenticated provider fact. @racket[payment-event?] and the accessors
above are exported by the facade; the raw constructor is not — adapters build
events through @racket[make-verified-payment-event] in
@racket[commerce/provider]. For a one-time fact, @racket[paid-through] stays
@racket[#f]; a subscription payment reports the epoch second through which the
provider says access is paid.}

@defstruct*[order-projection ([provider string?]
                              [order-id string?]
                              [offer-id string?]
                              [subject-id string?]
                              [amount money?]
                              [paid? boolean?]
                              [refunded? boolean?]
                              [paid-at (or/c exact-nonnegative-integer? #f)]
                              [refunded-at (or/c exact-nonnegative-integer? #f)]
                              [paid-through (or/c exact-nonnegative-integer? #f)])]{
The deterministic commercial state of one provider order.}

@defstruct*[rights-intent ([idempotency-key string?]
                           [action symbol?]
                           [provider string?]
                           [order-id string?]
                           [offer-id string?]
                           [subject-id string?]
                           [occurred-at exact-nonnegative-integer?])]{
One deterministic instruction for the Permit issuance boundary, emitted by
projection and consumed through the issuance outbox.}

@defproc[(empty-commerce-state) commerce-state?]{
Returns an empty immutable projection state.}

@defproc[(ingest-payment-event [state commerce-state?]
                               [event payment-event?])
         (values commerce-state? (listof rights-intent?))]{
Applies one previously verified provider event. Exact replay returns the same
state and an empty intent list. Conflicting replay or changed order identity
raises an @racket[exn:fail:commerce] value.}

@defproc[(commerce-state-order [state commerce-state?]
                               [provider string?]
                               [order-id string?])
         (or/c order-projection? #f)]{
Returns the current projection for one provider order.}

@defproc[(commerce-state-intents [state commerce-state?])
         (listof rights-intent?)]{
Returns all emitted rights intents sorted by their idempotency keys.}

@defstruct*[exn:fail:commerce ([message string?]
                               [continuation-marks continuation-mark-set?]
                               [code symbol?]
                               [data any/c])]{
The typed failure for every commercial refusal. Codes are kebab-case symbols;
@racket[data] is a redaction-safe hash. Raw provider bytes, signatures, and
key material never appear in the message or data.}

@section{Provider boundary}

@defmodule[commerce/provider]

Provider adapters require @racketmodname[commerce/provider] and construct a
canonical event only after authenticating the exact raw input, mapping the
Offer and subject, checking amount and currency, and performing any active
order lookup required by the provider contract.

@defproc[(make-verified-payment-event
          [provider string?]
          [event-id string?]
          [payload-digest string?]
          [kind symbol?]
          [order-id string?]
          [offer-id string?]
          [subject-id string?]
          [amount money?]
          [occurred-at exact-nonnegative-integer?]
          [#:paid-through paid-through
           (or/c exact-nonnegative-integer? #f) #f])
         payment-event?]{
Constructs the canonical event after the adapter's own authentication and
semantic checks. Product clients must not call this function.}

@defstruct*[checkout-session ([provider string?]
                              [session-id string?]
                              [url string?]
                              [expires-at exact-nonnegative-integer?])]{
One hosted checkout session returned by a provider adapter.}

@defstruct*[provider-adapter ([provider string?]
                              [verify (procedure?)])]{Opaque adapter value
binding one channel to its verification procedure.}

@section{Pancake webhook authentication}

@defmodule[commerce/pancake]

Server processes explicitly require @racketmodname[commerce/pancake]. This
module authenticates provider-native evidence and is not re-exported by the
default facade.

@defproc[(verify-pancake-webhook
          [raw-body bytes?]
          [signature-header string?]
          [#:environment environment (or/c 'test 'production)]
          [#:keyring keyring pancake-webhook-keyring?
           (default-pancake-webhook-keyring)]
          [#:now-ms now-ms exact-nonnegative-integer? (current-inexact-milliseconds)]
          [#:past-tolerance-ms past-tolerance-ms exact-nonnegative-integer? 2700000]
          [#:future-tolerance-ms future-tolerance-ms exact-nonnegative-integer? 60000])
         pancake-webhook?]{
Verifies the @tt{X-Waffo-Signature} RSA-SHA256 signature over the decimal
millisecond timestamp, one period byte, and the exact copied request bytes.
The default window accepts up to 45 minutes of retry age and one minute of
future clock skew. JSON parsing happens only after verification. The signed
payload's mode must match the explicitly selected environment, and duplicate
top-level fields are rejected.

The returned value exposes environment, envelope identifiers, event and store
metadata, data, immutable raw bytes, their SHA-256 digest, and the signature
timestamp through the @racket[pancake-webhook-*] accessors. It is
provider-native evidence and is not yet a canonical
@racket[payment-event].}

@defproc[(pancake-webhook-keyring [test-public-key non-empty-string?]
                                  [production-public-key non-empty-string?])
         pancake-webhook-keyring?]{
An explicit keyring supports controlled provider key rotation. Test and
production keys must be non-empty and distinct. Authentication and payload
failures raise redacted @racket[exn:fail:commerce] values; raw bodies,
signatures, and key contents are never included. Codes distinguish missing or
malformed signature headers, invalid or out-of-window timestamps, invalid
signatures, invalid configured public keys, invalid payloads, and environment
mismatch.}

@defproc[(verify-pancake-refund-webhook [raw-body bytes?]
                                        [signature-header string?]
                                        [#:environment environment (or/c 'test 'production)]
                                        [#:keyring keyring pancake-webhook-keyring?
                                         (default-pancake-webhook-keyring)])
         (values pancake-webhook? pancake-refund?)]{
Authenticates a signed refund webhook and extracts the refund record.
Refund handling is operator-facing: a refund never magically revokes an
offline credential.}

@defstruct*[pancake-refund ([order-id string?]
                            [event-id string?]
                            [currency string?]
                            [refunded-minor exact-nonnegative-integer?]
                            [original-charged-minor exact-nonnegative-integer?]
                            [external-id string?]
                            [occurred-at exact-nonnegative-integer?]
                            [raw-body bytes?]
                            [payload-digest string?])]{
One authenticated provider-native refund record.}

@defproc[(pancake-refund-payment-event [webhook pancake-webhook?]
                                       [refund pancake-refund?]
                                       [#:occurred-at occurred-at
                                        exact-nonnegative-integer?
                                        (current-seconds)])
         payment-event?]{
Derives the canonical refund event from authenticated refund evidence.}

@defproc[(strict-display-amount->minor [display-amount string?]
                                       [currency string?]
                                       [currency-exponent (integer-in 0 4)])
         money?]{
Converts a provider's decimal display amount directly to configured minor
units without floating point.}

@subsection{Pancake active one-time order verification}

@defstruct*[pancake-order-facts ([order-id string?]
                                 [status string?]
                                 [test-mode boolean?]
                                 [payment-id string?]
                                 [payment-status string?]
                                 [currency string?]
                                 [minor-units exact-nonnegative-integer?])]{
The actively read provider order facts.}

@defproc[(pancake-order-binding
          [merchant-external-id string?]
          [product-id string?]
          [offer-id string?]
          [subject-id string?]
          [amount money?]
          [currency-exponent (integer-in 0 4)])
         pancake-order-binding?]{
Records the server-side expectation created with checkout. The merchant
external id is a random correlation reference of at most 128 characters. It
maps locally to one provider product, stable Offer, opaque stable subject,
expected @racket[money] value, and explicit ISO 4217 exponent from zero
through four. It must not contain or substitute for the subject identity.}

@defproc[(make-pancake-merchant-client
          [merchant-id string?]
          [private-key-pem string?]
          [#:environment environment (or/c 'test 'production)]
          [#:connect-timeout-seconds connect-timeout exact-positive-integer? 5]
          [#:request-timeout-seconds request-timeout exact-positive-integer? 10]
          [#:transport transport (or/c procedure? #f) #f]
          [#:clock clock (or/c procedure? #f) #f])
         pancake-merchant-client?]{
Creates an opaque server-side client. The RSA private key is parsed once and
is not exposed by accessors. The client signs one @tt{POST /v1/graphql}
merchant read with RSA-SHA256/PKCS#1 v1.5. Both environments use
@tt{https://api.waffo.ai/v1/graphql}; the explicit environment is verified
against the returned order's @tt{testMode}. Defaults are five seconds to
connect and ten seconds for response headers and body. Reads follow no
redirects, carry no idempotency key, and make no implicit retry.}

@defproc[(read-pancake-onetime-order [client pancake-merchant-client?]
                                     [order-id string?])
         pancake-order-facts?]{
Actively reads one one-time order. Transport failure and HTTP 408/429/5xx
raise retryable @tt{pancake-order-unavailable}.}

@defproc[(pancake-order-binding? [value any/c]) boolean?]{
Recognizes one recorded server-side checkout expectation.}

@defproc[(pancake-merchant-client? [value any/c]) boolean?]{
Recognizes an opaque server-side Pancake merchant client; its private key is
never exposed by an accessor.}

@defproc[(verify-pancake-onetime-order [client pancake-merchant-client?]
                                       [webhook pancake-webhook?]
                                       [binding pancake-order-binding?])
         payment-event?]{
Requires an authenticated @tt{order.completed} webhook, actively reads its
one-time order, and checks order id, completed status, environment, store,
merchant external id, product, the webhook payment id and succeeded status,
currency, and exact payment total. Only a complete match constructs the
canonical event. Merchant authentication, GraphQL rejection, missing or
malformed orders, and each semantic mismatch have separate typed, redacted
codes. The optional transport and clock arguments on
@racket[make-pancake-merchant-client] exist for deterministic integration
testing; production callers normally leave them at their secure defaults.}

@section{Durable event journal}

@defmodule[commerce/journal]

Server processes explicitly require @racketmodname[commerce/journal]. It is
not re-exported from the default product-safe facade.

@defstruct*[journal-record ([sequence exact-nonnegative-integer?]
                            [event payment-event?]
                            [payload bytes?]
                            [received-at exact-nonnegative-integer?])]{
One durably accepted provider event: original sequence, canonical snapshot,
the exact raw payload bytes, and the receive time.}

@defstruct*[journal-acceptance ([disposition (or/c 'accepted 'replayed)]
                                [record journal-record?])]{
The acceptance disposition is @racket['accepted] for a newly committed row or
@racket['replayed] for an exact retry.}

@defproc[(journal-accept! [storage commerce-storage?]
                          [raw-payload bytes?]
                          [event payment-event?]
                          [#:received-at received-at exact-nonnegative-integer?])
         journal-acceptance?]{
Copies and hashes the exact authenticated bytes, then durably stores them with
the canonical payment-event snapshot. The same provider event id with changed
raw or canonical content raises an @racket[exn:fail:commerce] whose code is
@racket['event-conflict]. Digest mismatch is rejected before persistence.}

@defproc[(journal-ref [storage commerce-storage?]
                      [provider string?]
                      [event-id string?])
         (or/c journal-record? #f)]{
Returns the original sequence, canonical event, immutable raw payload, and
receive time.}

@section{Durable projection and issuance outbox}

@defmodule[commerce/storage]

Server processes explicitly require @racketmodname[commerce/storage]. It is
not re-exported from the default facade. Journal acknowledgement and
projection are separate durability phases. Projection runs outside the
provider request:

@defproc[(commerce-storage? [value any/c]) boolean?]{
Recognizes one opened durable Commerce storage. All journal, projection,
outbox, lineage, and claim operations accept only this type.}

@defproc[(storage-project-next! [storage commerce-storage?]
                                [#:processed-at processed-at exact-nonnegative-integer?])
         (or/c projection-result? #f)]{
Selects the lowest unprocessed journal sequence and atomically writes its
order projection, any newly emitted issuance-outbox row, and its processing
marker. It returns @racket[#f] when no sequence is pending. A successful
result has disposition @racket['projected]; an order identity conflict has
disposition @racket['blocked], failure code @racket['order-conflict], no new
outbox items, and leaves the previous order unchanged.}

@defstruct*[projection-result ([disposition (or/c 'projected 'blocked)]
                               [journal-sequence exact-nonnegative-integer?]
                               [order (or/c order-projection? #f)]
                               [outbox (listof issuance-outbox-item?)]
                               [failure-code (or/c symbol? #f)])]{
Exposes the projection disposition, journal sequence, resulting order, new
outbox items, and optional failure code.}

@defstruct*[issuance-outbox-item ([id exact-nonnegative-integer?]
                                  [idempotency-key string?]
                                  [source-sequence exact-nonnegative-integer?]
                                  [action symbol?]
                                  [provider string?]
                                  [order-id string?]
                                  [offer-id string?]
                                  [subject-id string?]
                                  [occurred-at exact-nonnegative-integer?]
                                  [status symbol?]
                                  [attempts exact-nonnegative-integer?]
                                  [available-at exact-nonnegative-integer?]
                                  [lease-owner (or/c string? #f)]
                                  [lease-expires-at (or/c exact-nonnegative-integer? #f)]
                                  [last-error-code (or/c symbol? #f)]
                                  [created-at exact-nonnegative-integer?]
                                  [updated-at exact-nonnegative-integer?]
                                  [completed-at (or/c exact-nonnegative-integer? #f)])]{
One durable issuance work row. New rows are @racket['pending] with zero
attempts and no lease.}

@defproc[(storage-order-ref [storage commerce-storage?]
                            [provider string?]
                            [order-id string?])
         (or/c order-projection? #f)]{
Returns the durable order projection.}

@defproc[(storage-outbox-ref [storage commerce-storage?]
                             [idempotency-key string?])
         (or/c issuance-outbox-item? #f)]{
Returns one outbox row by its stable idempotency key.}

@defproc[(storage-close [storage commerce-storage?]) void?]{
Closes the storage during service shutdown.}

@subsection{SQLite backend}

@defmodule[commerce/storage/sqlite]

@defproc[(open-sqlite-commerce-storage [database-path path-string?])
         commerce-storage?]{
Opens or creates a Commerce-owned SQLite database. Schema v8 uses WAL mode,
full commit synchronization, foreign keys, and database triggers that reject
updates or deletes of accepted event and entitlement-lineage evidence.
Earlier schema databases migrate in place without rewriting existing rows.
The lineage tables retain stable entitlement roots and contiguous revisions
with exact unsigned Permit payload bytes; no signer or signed-credential
storage is exposed.}

@defproc[(storage-readiness [storage commerce-storage?]
                            [#:now now exact-nonnegative-integer?])
         health-status?]{
The readiness snapshot behind @racket[commerce/health]; also re-exported
there.}

@subsection{Issuance lease state machine}

The issuance worker protocol is owner-safe: a row is claimed, signed work
happens outside the claim transaction, and completion or release re-checks
the lease owner against the database.

@defproc[(storage-claim-issuance-work! [storage commerce-storage?]
                                       [#:owner owner string?]
                                       [#:lease-seconds lease-seconds exact-positive-integer?]
                                       [#:now now exact-nonnegative-integer?])
         (or/c issuance-outbox-item? #f)]{
Claims the lowest due outbox row in one immediate transaction: status
@racket['processing], attempts incremented by one, and an opaque exclusive
lease bound to the owner. A row is due when it is @racket['pending] and
@racket[available_at <= now], or when its lease has expired. Returns
@racket[#f] when nothing is due.}

@defproc[(storage-complete-issuance-work! [storage commerce-storage?]
                                          [item issuance-outbox-item?]
                                          [#:issuer issuer string?]
                                          [#:subject-type subject-type string?]
                                          [#:entitlement-id entitlement-id string?]
                                          [#:credential-id credential-id string?]
                                          [#:policy-id policy-id string?]
                                          [#:policy-version policy-version exact-positive-integer?]
                                          [#:payload-bytes payload-bytes bytes?]
                                          [#:issued-at issued-at exact-nonnegative-integer?]
                                          [#:recorded-at recorded-at exact-nonnegative-integer?]
                                          [#:signed-credential-bytes envelope-bytes
                                           (or/c bytes? #f) #f]
                                          [#:key-id key-id (or/c string? #f) #f]
                                          [#:claim-token claim-token (or/c string? #f) #f]
                                          [#:claim-expires-at claim-expires-at
                                           (or/c exact-nonnegative-integer? #f) #f])
         issuance-completion?]{
Appends the lineage root together with revision zero, or exactly one
successor revision, and completes the outbox row inside the same short
transaction. The writer enforces the ADR-0008 identity rules as typed
failures before any insert: a second grant over an existing lineage, a
commercial identity bound to a different entitlement, a withdrawal without
a lineage, and a credential id already bound to another revision raise
@racket[exn:fail:commerce] codes @racket['entitlement-lineage-conflict] or
@racket['entitlement-lineage-required] and write nothing. The payload digest
is computed from the given bytes, never trusted from the caller. Completion
without the active lease raises @racket['lease-not-held]. Repeating a
completion that already landed reconciles to the recorded revision; the same
outbox id with different payload bytes is a conflict. When the exact signed
envelope bytes and key id are supplied, the completion transaction also
records the issued credential; a claim token and expiry add its one-time
fulfillment claim. Omitting them records issuance evidence without
delivery.}

@defproc[(storage-release-issuance-work! [storage commerce-storage?]
                                         [item issuance-outbox-item?]
                                         [#:error-code error-code symbol?]
                                         [#:retry-at retry-at exact-nonnegative-integer?])
         issuance-outbox-item?]{
Returns transient work to @racket['pending] with the typed error code
recorded and a future retry time. Only the lease owner may release; attempts
stay exactly as the claim incremented them.}

@defproc[(storage-entitlement-ref [storage commerce-storage?]
                                  [entitlement-id string?])
         (or/c entitlement-lineage? #f)]{
Returns the durable lineage for one entitlement id.}

@defproc[(storage-lineage-ref [storage commerce-storage?]
                              [#:issuer issuer string?]
                              [#:subject-type subject-type string?]
                              [#:subject-id subject-id string?]
                              [#:offer-id offer-id string?])
         (or/c entitlement-lineage? #f)]{
Resolves the lineage bound to one commercial identity.}

@defproc[(storage-entitlement-revision-ref [storage commerce-storage?]
                                           [entitlement-id string?]
                                           [revision exact-nonnegative-integer?])
         (or/c entitlement-revision? #f)]{
Returns one recorded revision. Revision payload bytes are the exact
unsigned snapshot bytes, never signed credential bytes.}

@defproc[(storage-latest-entitlement-revision [storage commerce-storage?]
                                              [entitlement-id string?])
         (or/c entitlement-revision? #f)]{
Returns the newest recorded revision of one lineage.}

@defstruct*[entitlement-lineage ([entitlement-id string?]
                                 [issuer string?]
                                 [subject-type string?]
                                 [subject-id string?]
                                 [offer-id string?]
                                 [created-at exact-nonnegative-integer?])]{
The stable entitlement root bound to one commercial identity.}

@defstruct*[entitlement-revision ([entitlement-id string?]
                                  [revision exact-nonnegative-integer?]
                                  [previous-revision
                                   (or/c exact-nonnegative-integer? #f)]
                                  [credential-id string?]
                                  [issuance-outbox-id exact-nonnegative-integer?]
                                  [action symbol?]
                                  [policy-id string?]
                                  [policy-version exact-positive-integer?]
                                  [payload-bytes bytes?]
                                  [payload-digest string?]
                                  [issued-at exact-nonnegative-integer?]
                                  [recorded-at exact-nonnegative-integer?])]{
One recorded lineage revision. @racket[payload-bytes] is the exact unsigned
snapshot bytes, never signed credential bytes.}

@defstruct*[issuance-completion ([outbox issuance-outbox-item?]
                                 [revision exact-nonnegative-integer?])]{
The durable result of one completed issuance work item.}

@defstruct*[issued-credential-record ([id exact-nonnegative-integer?]
                                      [issuance-outbox-id exact-nonnegative-integer?]
                                      [entitlement-id string?]
                                      [revision exact-nonnegative-integer?]
                                      [credential-id string?]
                                      [key-id string?]
                                      [envelope-bytes bytes?]
                                      [created-at exact-nonnegative-integer?])]{
The durable signed-credential audit record. @racket[envelope-bytes] is the
exact serialized Permit envelope (key id, payload, signature) as delivered.}

@defstruct*[claim-fulfillment ([claim-id string?]
                               [credential issued-credential-record?]
                               [claimed-at exact-nonnegative-integer?])]{
The result of fulfilling one claim token.}

@subsection{One-time claim delivery}

The issued credential record retains the exact signed envelope bytes; the
claim stores only the token's SHA-256 digest. No transport or HTTP listener
is included in this boundary.

@defproc[(storage-claim-credential [storage commerce-storage?]
                                   [#:token token string?]
                                   [#:now now exact-nonnegative-integer?])
         claim-fulfillment?]{
Verifies the token, its state, and its fulfillment window, marks the claim
claimed, and returns the claim id, the fulfillment time, and the
@racket[issued-credential-record] with the exact signed envelope bytes,
which verify as a Permit envelope for the recorded key id. Wrong, reused,
and expired tokens raise typed @racket[exn:fail:commerce] values
(@racket['claim-not-found], @racket['claim-already-claimed],
@racket['claim-expired]) and mutate nothing. Fulfillment never creates or
advances a lineage revision.}

@defproc[(storage-mark-claim-notified [storage commerce-storage?]
                                      [#:token token string?]
                                      [#:now now exact-nonnegative-integer?])
         void?]{
Records that a delivery transport handed the token out. The first
notification timestamp wins; later retries are idempotent no-ops.}

@defproc[(storage-retire-expired-claims! [storage commerce-storage?]
                                         [#:now now exact-nonnegative-integer?])
         exact-nonnegative-integer?]{
Marks expired unfulfilled claims retired; returns the number retired.
Exposed to operators through @racket[commerce/retention].}

@section{Offer-to-Permit policy mapping}

@defmodule[commerce/permit]

Server processes explicitly require @racketmodname[commerce/permit]. This
module imports the published @racketmodname[permit/issuer] snapshot surface;
it is not re-exported from the default facade and never accesses a signing
key.

@defproc[(permit-grant-policy? [value any/c]) boolean?]{
Recognizes one validated grant policy.}

@defproc[(permit-constraints-policy? [value any/c]) boolean?]{
Recognizes one validated constraints policy.}

@defproc[(permit-entitlement-policy? [value any/c]) boolean?]{
Recognizes one immutable, versioned entitlement policy.}

@defproc[(permit-policy-catalog? [value any/c]) boolean?]{
Recognizes one reviewed policy catalog.}

@defproc[(make-permit-grant-policy
          [#:products products (or/c hash? #f) #f]
          [#:product-families product-families (or/c hash? #f) #f]
          [#:edition edition (or/c string? #f) #f]
          [#:feature-policy feature-policy (or/c 'explicit 'published-through) #f]
          [#:features features (or/c hash? #f) #f]
          [#:addons addons (or/c hash? #f) #f]
          [#:capabilities capabilities (or/c hash? #f) #f])
         permit-grant-policy?]{
Constructs one reviewed grant policy. Optional Commerce values use
@racket[#f]; the adapter translates absence to Permit @racket[null]. The
smart constructor validates the resulting grant through Permit's complete
entitlement schema.}

@defproc[(make-permit-constraints-policy
          [#:use-expires-at use-expires-at (or/c string? #f) #f]
          [#:updates-through updates-through (or/c string? #f) #f]
          [#:features-through features-through (or/c string? #f) #f]
          [#:version-min version-min (or/c string? #f) #f]
          [#:version-max version-max (or/c string? #f) #f]
          [#:named-seats named-seats (or/c exact-nonnegative-integer? #f) #f]
          [#:device-activations device-activations (or/c exact-nonnegative-integer? #f) #f]
          [#:concurrent-seats concurrent-seats (or/c exact-nonnegative-integer? #f) #f]
          [#:installation-id installation-id (or/c string? #f) #f]
          [#:activation-required? activation-required? boolean? #f])
         permit-constraints-policy?]{
Constructs the complete constraints policy and validates timestamps, SemVer
bounds, limits, installation binding, and activation shape through Permit.}

@defproc[(make-permit-entitlement-policy
          [id string?]
          [version exact-positive-integer?]
          [#:subject-type subject-type string?]
          [#:grants grants permit-grant-policy?]
          [#:constraints constraints permit-constraints-policy? #f]
          [#:withdrawal-mode withdrawal-mode symbol? 'expire-at-issuance])
         permit-entitlement-policy?]{
Binds one policy id, audit version, subject type, grants, and optional
constraints. Policy ids are immutable revisions; the positive integer
version is audit metadata and never selects a mutable latest policy.}

@defproc[(make-permit-policy-catalog
          [offers hash?]
          [policies hash?]
          [#:deleted-offer-ids deleted-offer-ids (listof string?) '()])
         permit-policy-catalog?]{
The catalog contains both active and retained retired Offer definitions.
Explicit deletion tombstones are distinct from never-known Offer ids. Every
Offer's product must occur in the explicit product scope of its pinned
policy.}

@defproc[(prepare-permit-snapshot
          [catalog permit-policy-catalog?]
          [intent rights-intent?]
          [#:issuer issuer string?]
          [#:credential-id credential-id string?]
          [#:entitlement-id entitlement-id string?]
          [#:issued-at issued-at exact-nonnegative-integer?]
          [#:previous previous (or/c entitlement-revision? #f) #f])
         permit-snapshot-request?]{
For @racket['grant], creates a complete entitlement at revision 0 and
rejects an existing lineage. For @racket['withdraw], requires the previous
complete snapshot, checks issuer, entitlement id, subject, type, and grants,
advances its revision, and sets @racket[use_expires_at] to the new
@racket[issued_at]. This communicates an issuance-expiring successor to
connected clients; it does not revoke an old offline credential.

The result exposes policy id/version, action, source idempotency key, the
validated complete payload, and
@racket[permit-snapshot-request-payload-bytes]. The payload tree and bytes
are immutable copies. Those bytes are Permit's single serialization and are
the only bytes a later signer may sign. Unknown/deleted Offers, invalid
policy/catalog/request data, unsupported actions, and missing or conflicting
lineage raise typed @racket[exn:fail:commerce] values. The optional
@racket[#:use-expires-at] overrides the successor's @racket[use_expires_at]:
a withdrawal for a subscription order expires at the paid-through moment
(cancellation at period end), and the @racket['renew] action — a successor
over the previous revision of the same lineage — requires it. No outbox
mutation, lineage persistence, signing, or delivery happens in this
operation.}

@defproc[(permit-snapshot-request? [value any/c]) boolean?]{
Recognizes one validated snapshot request.}

@defproc[(permit-snapshot-request-payload-bytes
          [request permit-snapshot-request?])
         bytes?]{
Returns the immutable validated payload bytes — Permit's single
serialization and the only bytes a later signer may sign.}

@defproc[(permit-policy-for-offer [catalog permit-policy-catalog?]
                                  [offer-id string?])
         permit-entitlement-policy?]{
Resolves the pinned policy for one Offer with the same typed failures as
snapshot preparation, so a worker can fail before signing.}

@section{Explicit issuer worker}

@defmodule[commerce/issuer]

Server processes explicitly require @racketmodname[commerce/issuer]. This
module imports the published @racketmodname[permit/issuer] signing surface;
the default facade never does. The worker owns no durable state: every
decision derives from the claimed outbox row, the pinned catalog, and
recorded lineage.

@defproc[(make-issuance-worker
          [#:catalog catalog permit-policy-catalog?]
          [#:issuer issuer string?]
          [#:private-key private-key any/c]
          [#:key-id key-id string?]
          [#:trust-store trust-store any/c]
          [#:clock clock procedure? default-clock]
          [#:owner owner string? default-owner]
          [#:lease-seconds lease-seconds exact-positive-integer? default-lease-seconds]
          [#:transient-backoff-seconds transient-backoff exact-nonnegative-integer?
           default-transient-backoff]
          [#:operator-backoff-seconds operator-backoff exact-nonnegative-integer?
           default-operator-backoff])
         issuance-worker?]{
Binds one reviewed catalog, issuer identity, Ed25519 private key, trust
store key id, and trust store behind one opaque worker value. The private
key is never exposed by an accessor. The clock returns two values, an epoch
second and its RFC 3339 string; the default reads wall-clock UTC.}

@defproc[(process-issuance-work! [worker issuance-worker?]
                                 [storage commerce-storage?])
         (or/c issuance-result? #f)]{
Claims one due outbox row and drives it: deterministic dead ends are
released with their typed commerce code and an operator backoff before any
signing; a grant with no lineage signs revision zero and a withdrawal signs
an issuance-expiring successor naming the latest revision; the exact
recorded bytes are signed outside the claim transaction, and the revision,
the signed envelope, and a one-time claim are recorded in one transaction.
The result's claim token is delivered to the caller exactly once for a
single customer handoff. Returns @racket[#f] when nothing is due.
Dispositions: @racket['completed] with the storage completion record and
claim token, @racket['released] with the typed error code, or
@racket['lease-lost] when the lease expired between claim and completion, in
which case nothing was written. Permit signing failures release as
@racket['permit-issue-failed] with the transient backoff; the same durable
work completes after repair.}

@defstruct*[issuance-result ([disposition symbol?]
                             [completion (or/c issuance-completion? #f)]
                             [error-code (or/c symbol? #f)]
                             [entitlement-id (or/c string? #f)]
                             [revision (or/c exact-nonnegative-integer? #f)]
                             [claim-token (or/c string? #f)])]{
One worker turn's outcome.}

@defproc[(derive-entitlement-id [issuer string?]
                                [subject-type string?]
                                [subject-id string?]
                                [offer-id string?])
         string?]{
Deterministic lineage identifier. Reprocessing never allocates a second
lineage or revision; a crash after signing converges because Ed25519
re-signs identical bytes to an identical signature.}

@defproc[(derive-credential-id [entitlement-id string?]
                               [revision exact-nonnegative-integer?])
         string?]{
Deterministic credential identifier for one lineage revision.}

@section{Provider admission}

@defmodule[commerce/admission]

Server processes explicitly require @racketmodname[commerce/admission]. A
provider admission record is the reviewed, file-carried permission that
turns configured channel credentials into an authorized checkout: no
admission, no checkout, even with valid keys.

@defproc[(provider-admission? [value any/c]) boolean?]{
Recognizes one read admission record.}

@defproc[(read-provider-admission [path path-string?]) provider-admission?]{
Reads and validates one admission record. Missing, oversized, malformed,
duplicate-key, or unapproved records refuse before any network call or
database checkout binding is made.}

@defproc[(authorize-provider-checkout!
          [admission provider-admission?]
          [#:provider provider string?]
          [#:environment environment (or/c "sandbox" "production")]
          [#:merchant-app-id app string?]
          [#:seller-id seller string?]
          [#:product-id product string?]
          [#:offer-id offer string?]
          [#:payment-method method string?]
          [#:transaction-type transaction string?]
          [#:amount amount money?]
          [#:at now exact-nonnegative-integer? (current-seconds)])
         void?]{
Checks the checkout request against the admission record — provider,
environment, app, seller, product, offer, payment method, transaction type,
and amount bounds — and refuses with a typed @racket[exn:fail:commerce]
before any provider call when anything is outside the approved record.}

@section{Issuance evidence verification}

@defmodule[commerce/evidence]

Server processes explicitly require @racketmodname[commerce/evidence]. The
evidence verifier re-checks that a journal record actually proves the
commercial identity an outbox row claims before signing: catalog and claim
match, binding amounts match, and channel-native evidence is verified
again — independently of the webhook edge that accepted it.

@defproc[(make-issuance-evidence-verifier
          [#:catalog catalog permit-policy-catalog?]
          [#:alipay-public-key-pem alipay-public-key-pem (or/c string? #f) #f]
          [#:pancake-keyring pancake-keyring pancake-webhook-keyring?
           (default-pancake-webhook-keyring)]
          [#:binding-lookup binding-lookup (or/c procedure? #f) #f])
         issuance-evidence-verifier?]{
Binds the pinned catalog and the channel verification material behind one
opaque verifier.}

@defproc[(issuance-evidence-verifier? [value any/c]) boolean?]{
Recognizes one opaque evidence verifier.}

@defproc[(verify-issuance-evidence!
          [verifier issuance-evidence-verifier?]
          [record journal-record?]
          [claimed-offer-id string?]
          [claimed-subject-id string?])
         void?]{
Re-verifies the journaled evidence for one claimed Offer and subject.
Mismatched fields, forged bytes, and failed channel re-verification raise
typed @racket[exn:fail:commerce] refusals before any signing happens.}

@section{Reconciliation}

@defmodule[commerce/reconcile]

Server processes explicitly require @racketmodname[commerce/reconcile].
Reconciliation actively reads provider order facts and compares them with
the durable projection; it reports differences, it never mutates the
projection.

@defstruct*[reconciliation-difference ([order-id string?]
                                       [code symbol?]
                                       [detail string?])]{
One bounded, redacted difference between the provider's answer and the
recorded projection.}

@defproc[(reconcile-orders [storage commerce-storage?]
                           [client pancake-merchant-client?]
                           [orders (listof (cons/c string? pancake-order-binding?))])
         (listof reconciliation-difference?)]{
Actively reads each bound order and compares status, environment, and
amount with the projection. Differences are returned sorted by order id.}

@section{HTTP edge and claim portal}

@defmodule[commerce/server]

Server processes explicitly require @racketmodname[commerce/server]. The
edge binds webhook authentication, active order verification, journal
acceptance, and the one-time claim portal behind one small HTTP surface;
it is a thin adapter, and the journal's idempotence decides every
acknowledgement.

@defproc[(make-webhook-endpoint
          [#:keyring keyring pancake-webhook-keyring?]
          [#:environment environment (or/c 'test 'production)]
          [#:merchant-client merchant-client pancake-merchant-client?]
          [#:binding-lookup binding-lookup procedure?]
          [#:storage storage commerce-storage?])
         webhook-endpoint?]{
Binds one Pancake channel to its keyring, merchant client, binding lookup,
and storage.}

@defproc[(webhook-endpoint? [value any/c]) boolean?]{
Recognizes one bound Pancake webhook endpoint.}

@defproc[(handle-webhook-post [endpoint webhook-endpoint?]
                              [raw-body bytes?]
                              [signature-header string?])
         (values exact-nonnegative-integer? jsexpr?)]{
Pure webhook handling: exact body bytes plus the signature header in, HTTP
status and JSON body out. The order is deliberate: signature first, then
binding resolution, then active verification, then journal acceptance.}

@defproc[(handle-claim-post [endpoint webhook-endpoint?]
                            [token string?])
         (values exact-nonnegative-integer? jsexpr?)]{
Fulfills a one-time claim token. Unknown claims answer 404, reused claims
409, expired claims 410, and other refusals 422 — a fulfilled claim returns
the exact signed Permit envelope as JSON, once.}

@defproc[(handle-readyz [endpoint webhook-endpoint?])
         (values exact-nonnegative-integer? jsexpr?)]{
Renders the storage readiness snapshot for the load balancer.}

@defproc[(serve-webhook-endpoint [endpoint webhook-endpoint?]
                                 [#:port port exact-nonnegative-integer?]
                                 [#:listen-ip listen-ip string? "127.0.0.1"])
         (-> void?)]{
Binds the endpoint to an HTTP port and returns a zero-argument shutdown
procedure. The servlet exposes exactly three routes —
@tt{/webhooks/pancake}, @tt{/claims}, and @tt{/readyz}; anything else is
404.}

@section{Backup, verification and retention}

@defmodule[commerce/backup]

Server processes explicitly require @racketmodname[commerce/backup]. Backups
are only evidence when they are verified against the running store.

@defproc[(snapshot-commerce-database! [database-path path-string?]
                                      [destination-path path-string?])
         void?]{
Produces a consistent SQLite backup of a Commerce-owned database through
SQLite's online backup API, read-only on the source.}

@defstruct*[backup-verification ([ok? boolean?]
                                 [details hash?])]{
The verification verdict with its checked details, including the backup's
schema version.}

@defproc[(verify-commerce-backup [original-storage commerce-storage?]
                                 [backup-path path-string?]
                                 [#:now now exact-nonnegative-integer?])
         backup-verification?]{
Opens the backup read-only and verifies its schema version and recorded
facts against the original storage. A backup that does not match the
original's schema version is not a usable backup.}

@section{Purchase progress}

@defmodule[commerce/purchase-progress]

Server processes explicitly require
@racketmodname[commerce/purchase-progress]. Products may read an
authenticated purchase progress snapshot; it is status reporting and never
authorization.

@defproc[(current-purchase-progress [storage commerce-storage?]
                                    [#:provider provider string?]
                                    [#:order-id order-id string?]
                                    [#:product-id product string?]
                                    [#:offer-id offer string?]
                                    [#:subject-id subject string?]
                                    [#:authorize authorize procedure?])
         (or/c hash? #f)]{
Returns the redacted progress status for one order after the caller's own
authorization check; authorization is a product decision, not a Commerce
one. A paid flag here never authorizes a feature.}

@section{Hosted checkout HTTP}

@defmodule[commerce/checkout-http]

Server processes explicitly require
@racketmodname[commerce/checkout-http]. The checkout transport turns one
authenticated product request into one admitted, admission-checked, and
once-only provider checkout — trusted server-side pricing, never a public
checkout API.

@defproc[(make-checkout-http-service
          [#:admission admission provider-admission?]
          [#:admission-json admission-json hash?]
          [#:storage storage commerce-storage?]
          [#:signer signer procedure?]
          [#:service-id service-id string?]
          [#:service-key service-key bytes?]
          [#:issuer issuer string?]
          [#:app-id app-id string?]
          [#:seller-id seller-id string?]
          [#:gateway gateway string?]
          [#:notify-url notify-url string?]
          [#:return-url return-url string?]
          [#:claim-once! claim-once! procedure?]
          [#:clock clock procedure? current-seconds])
         checkout-http-service?]{
Binds one admission record, its parsed JSON, storage, the request signer,
channel gateway configuration, and the product-side once-only claim
callback behind one opaque service.}

@defproc[(checkout-http-service? [value any/c]) boolean?]{
Recognizes one bound checkout HTTP service.}

@defproc[(handle-checkout-http-post [service checkout-http-service?]
                                    [#:method method string?]
                                    [#:path path string?]
                                    [#:body raw bytes?]
                                    [#:headers headers any/c]
                                    [#:now now exact-nonnegative-integer?])
         (values exact-nonnegative-integer? bytes?)]{
Handles one checkout POST. The admission record authorizes the product,
offer, and amount before any provider call; a request id gives one order
per product request id; failures deny with a bounded, redacted JSON body.}

@section{Structured event logging}

@defmodule[commerce/log]

Processes explicitly require @racketmodname[commerce/log] to observe their
own transitions. Events are structured and redacted by construction:
correlation keys are a closed whitelist (provider, event id, order id,
subject, offer, outbox work, entitlement and revision, claim, sequence) and
field values are redaction-safe scalars — strings, exact integers,
booleans, and kebab-case workflow or error symbols. Raw provider bytes,
tokens, and unlisted keys are rejected before emission.

@defproc[(log-commerce-event! [level symbol?]
                              [code symbol?]
                              [correlation (hash/c symbol?
                                                   (or/c string?
                                                         exact-nonnegative-integer?
                                                         #f))]
                              [fields hash?])
         void?]{
Emits one structured, redacted event at @racket['debug], @racket['info],
@racket['warning], or @racket['error]. Public surfaces instrument their own
transitions: journal acceptance and conflict, projection and blocking,
lease claim/complete/release, redrive, and claim fulfillment or refusal.
Exact replays and idle polling log at @racket['debug]; transitions log at
@racket['info]; conflicts, refusals, and lost leases log at
@racket['warning]. Transport formatting and shipping are deployment
concerns.}

@defthing[commerce-logger logger?]{
The commerce topic logger; the health reporter emits typed warnings on it.}

@section{Readiness and health}

@defmodule[commerce/health]

Processes explicitly require @racketmodname[commerce/health].

@defstruct*[health-warning ([code symbol?] [detail hash?])]{
One typed warning.}

@defstruct*[health-status ([readiness any/c]
                           [warnings (listof health-warning?)])]{
One read-only aggregate: the readiness snapshot (schema version, journal and
projection counts, pending and processing issuance work with a stale-lease
count, the oldest pending availability time, and claim state counts
including the window-passed count) plus the typed warnings.}

@defproc[(health-report [storage commerce-storage?]
                        [#:now now exact-nonnegative-integer?])
         health-status?]{
Classifies the snapshot into typed warnings —
@racket['projection-blocked], @racket['issuance-lease-expired],
@racket['claim-window-passed]. Nothing mutates; an HTTP edge renders this
value.}

@defproc[(health-report! [storage commerce-storage?]
                         [#:now now exact-nonnegative-integer?])
         health-status?]{
The logging variant: emits the warnings on the commerce topic.}

@section{Operator surface}

@defmodule[commerce/operator]

Server processes explicitly require @racketmodname[commerce/operator]. The
surface answers operator questions without exposing raw provider bytes;
deep journal payload access stays behind
@racketmodname[commerce/journal].

@defproc[(find-issuance-work [storage commerce-storage?]
                             [#:status status (or/c symbol? #f) #f])
         (listof issuance-outbox-item?)]{
Enumeration is read-only and stable by id.}

@defstruct*[order-explanation ([order (or/c order-projection? #f)]
                               [events (listof payment-event?)]
                               [work (listof issuance-outbox-item?)]
                               [credentials (listof issued-credential-record?)])]{
The explanation carries the order projection, the canonical event snapshots
(never raw provider payloads), the order's outbox work, and its
issued-credential records if any.}

@defproc[(explain-order [storage commerce-storage?]
                        [provider string?]
                        [order-id string?])
         order-explanation?]{
Explains one order from durable state only.}

@defproc[(redrive-issuance-work! [storage commerce-storage?]
                                 [idempotency-key string?]
                                 [#:now now exact-nonnegative-integer?])
         issuance-outbox-item?]{
Makes one @racket['pending] row due immediately without touching its
attempts counter — the bounded answer to transient failures and short
backoffs. It refuses to rewind in-flight work (@racket['lease-not-held])
or completed work (@racket['work-already-completed]), and unknown keys fail
with @racket['unknown-issuance-work]. Replay always reuses the immutable
journal through the normal projection path; no operation edits a projection
row.}

@subsection{Operator CLI}

@verbatim{
raco commerce doctor   <database>
raco commerce find     <database>
raco commerce explain  <database> <provider> <order-id>
raco commerce redrive  <database> <idempotency-key>
}

@tt{raco commerce} wraps @racketmodname[commerce/operator] for one service
database. Output is JSON with redacted summaries; @tt{doctor} exits 0 when
the readiness snapshot has no warnings and 1 otherwise, and @tt{redrive}
exits 0 on success and 1 with a typed code on refusal.

@tt{doctor <database>} is the read-only first-line probe: it reports the
storage schema version, journal/projection counts, pending and stale-lease
work, claim state, and every typed health warning in one JSON object. It
opens the database with SQLite read-only access, never creates an index or
migrates a schema, and reports a typed refusal for an absent or
incompatible database. Use @tt{find|explain|redrive} for the follow-up
action.}

@section[#:tag "commerce-hosted-services"]{Hosted services and channel integrations (development)}

@defmodule[commerce/hosted-registry]

The hosted-service family — @racketmodname[commerce/hosted-registry],
@racketmodname[commerce/hosted-auth], @racketmodname[commerce/hosted-admission],
@racketmodname[commerce/hosted-entitlement], @racketmodname[commerce/hosted-proof],
and @racketmodname[commerce/hosted-http] — implements the product-neutral
hosted entitlement bridge (ADR-0021) with signed grant/withdrawal
high-water fencing for trusted product servers. These modules are
implemented and CI-tested but not live: their contracts are still governed
by @filepath{docs/hosted-permit-proof.md},
@filepath{docs/hosted-consumer-watermarks.md},
@filepath{docs/hosted-admission.md}, and
@filepath{docs/hosted-proof-http.md}, which are explicit about their
development and draft status. Read those documents before consuming any of
these modules; this manual deliberately does not freeze their signatures.

@defmodule[commerce/alipay]

@racketmodname[commerce/alipay] and its hosted replay backend implement the
Alipay channel adapter: durable refund operations (ADR-0022), trusted
checkout coordination (ADR-0023), and the authenticated loopback checkout
transport (ADR-0024). The adapter is an integration candidate, not a live
channel; @filepath{docs/alipay-vibe-pay.md} is the canonical operational
description and @filepath{deploy/README.md} the deployment assembly.

@section{First purchase}

@verbatim{
#lang racket/base

(require commerce
         commerce/provider)

(define paid
  (make-verified-payment-event
   "mock" "evt_1" (make-string 64 #\a)
   'payment-succeeded
   "ord_1" "taskly-pro-lifetime" "customer-1"
   (money "USD" 2900)
   1792108800))

(define-values (state intents)
  (ingest-payment-event (empty-commerce-state) paid))
}

@section{Further reading}

The complete architecture, provider rules, security model, operations
contract, and Permit integration are maintained in the repository's
@filepath{docs/} directory, with the decision records under
@filepath{docs/decisions/}. @hyperlink["https://github.com/turlamai/commerce"]{github.com/turlamai/commerce}
hosts the source and the issue tracker.
