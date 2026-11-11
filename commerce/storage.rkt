#lang racket/base

(provide
 commerce-storage?
 projection-result?
 projection-result-disposition
 projection-result-journal-sequence
 projection-result-order
 projection-result-outbox
 projection-result-failure-code
 issuance-outbox-item?
 issuance-outbox-item-id
 issuance-outbox-item-idempotency-key
 issuance-outbox-item-source-sequence
 issuance-outbox-item-action
 issuance-outbox-item-provider
 issuance-outbox-item-order-id
 issuance-outbox-item-offer-id
 issuance-outbox-item-subject-id
 issuance-outbox-item-occurred-at
 issuance-outbox-item-status
 issuance-outbox-item-attempts
 issuance-outbox-item-available-at
 issuance-outbox-item-lease-owner
 issuance-outbox-item-lease-expires-at
 issuance-outbox-item-last-error-code
 issuance-outbox-item-created-at
 issuance-outbox-item-updated-at
 issuance-outbox-item-completed-at
 entitlement-lineage?
 entitlement-lineage-entitlement-id
 entitlement-lineage-issuer
 entitlement-lineage-subject-type
 entitlement-lineage-subject-id
 entitlement-lineage-offer-id
 entitlement-lineage-created-at
 entitlement-revision?
 entitlement-revision-entitlement-id
 entitlement-revision-revision
 entitlement-revision-previous-revision
 entitlement-revision-credential-id
 entitlement-revision-issuance-outbox-id
 entitlement-revision-action
 entitlement-revision-policy-id
 entitlement-revision-policy-version
 entitlement-revision-payload-bytes
 entitlement-revision-payload-digest
 entitlement-revision-issued-at
 entitlement-revision-recorded-at
 issuance-completion?
 issuance-completion-outbox
 issuance-completion-revision
 issued-credential-record?
 issued-credential-record-id
 issued-credential-record-issuance-outbox-id
 issued-credential-record-entitlement-id
 issued-credential-record-revision
 issued-credential-record-credential-id
 issued-credential-record-key-id
 issued-credential-record-envelope-bytes
 issued-credential-record-created-at
 claim-fulfillment?
 claim-fulfillment-claim-id
 claim-fulfillment-credential
 claim-fulfillment-claimed-at
 readiness?
 readiness-schema-version
 readiness-journal-total
 readiness-journal-unprojected
 readiness-projection-blocked
 readiness-work-pending
 readiness-work-processing
 readiness-work-stale-lease
 readiness-work-oldest-pending-at
 readiness-claim-ready
 readiness-claim-claimed
 readiness-claim-window-passed
 storage-project-next!
 storage-claim-issuance-work!
 storage-complete-issuance-work!
 storage-release-issuance-work!
 storage-order-ref
 storage-outbox-ref
 storage-entitlement-ref
 storage-lineage-ref
 storage-entitlement-revision-ref
 storage-latest-entitlement-revision
 storage-latest-entitlement-revision-and-unresolved-refund
 storage-claim-credential
 storage-mark-claim-notified
 storage-outbox-scan
 storage-order-journal
 storage-journal-sequence-ref
 storage-order-outbox
 storage-issued-credential-ref
 storage-redrive-issuance-work!
 storage-readiness
 storage-retire-expired-claims!
 checkout-binding
 checkout-binding?
 checkout-binding-merchant-external-id
 checkout-binding-provider
 checkout-binding-product-id
 checkout-binding-offer-id
 checkout-binding-subject-id
 checkout-binding-currency
 checkout-binding-amount-minor-units
 checkout-binding-currency-exponent
 storage-create-checkout-binding!
 storage-checkout-binding-ref
 operator-audit-record?
 operator-audit-record-id
 operator-audit-record-action
 operator-audit-record-operator
 operator-audit-record-reason
 operator-audit-record-subject
 operator-audit-record-created-at
 claim-record?
 claim-record-id
 claim-record-claim-token-digest
 claim-record-issued-credential-id
 claim-record-status
 claim-record-notified-at
 claim-record-claimed-at
 claim-record-expires-at
 claim-record-created-at
 claim-record-updated-at
 storage-append-audit!
 storage-audit-scan
 storage-reissue-claim!
 storage-unresolved-refund?
 storage-close)

(require racket/list
         "log.rkt"
         "private/model.rkt"
         "private/storage-model.rkt")

(define (check-storage who storage)
  (unless (commerce-storage? storage)
    (raise-argument-error who "commerce-storage?" storage)))

(define (check-claimed-work who item)
  (unless (issuance-outbox-item? item)
    (raise-argument-error who "issuance-outbox-item?" item)))

(define (check-timestamp who value)
  (unless (exact-nonnegative-integer? value)
    (raise-argument-error
     who "exact-nonnegative-integer?" value)))

(define (check-typed-code who value)
  (unless (stable-id? (if (symbol? value) (symbol->string value) ""))
    (raise-argument-error
     who "stable kebab-case error symbol" value))
  value)

(define (storage-project-next! storage #:processed-at processed-at)
  (check-storage 'storage-project-next! storage)
  (unless (exact-nonnegative-integer? processed-at)
    (raise-argument-error
     'storage-project-next! "exact-nonnegative-integer?" processed-at))
  (define result
    ((commerce-storage-project-next storage) processed-at))
  (when result
    (cond
      [(eq? (projection-result-disposition result) 'projected)
       (log-commerce-event!
        'info 'projection-projected
        (hash 'sequence (projection-result-journal-sequence result))
        (hash 'work (length (projection-result-outbox result))))]
      [else
       (log-commerce-event!
        'warning 'projection-blocked
        (hash 'sequence (projection-result-journal-sequence result))
        (hash 'failure-code (projection-result-failure-code result)))]))
  result)

(define (storage-order-ref storage provider order-id)
  (check-storage 'storage-order-ref storage)
  (unless (stable-id? provider)
    (raise-argument-error
     'storage-order-ref "stable kebab-case provider identifier" provider))
  (unless (opaque-id? order-id)
    (raise-argument-error
     'storage-order-ref "non-empty opaque provider order identifier" order-id))
  ((commerce-storage-order-lookup storage) provider order-id))

(define (storage-outbox-ref storage idempotency-key)
  (check-storage 'storage-outbox-ref storage)
  (unless (and (string? idempotency-key)
               (<= 1 (string-length idempotency-key) 512))
    (raise-argument-error
     'storage-outbox-ref "non-empty idempotency key up to 512 characters"
     idempotency-key))
  ((commerce-storage-outbox-lookup storage) idempotency-key))

;; Claims the lowest due outbox row for one owner. Active leases are
;; exclusive; an expired lease may be reclaimed by any owner, and the
;; reclaim is observable through the attempts counter.
(define (storage-claim-issuance-work! storage
                                      #:owner owner
                                      #:lease-seconds lease-seconds
                                      #:now now)
  (check-storage 'storage-claim-issuance-work! storage)
  (unless (opaque-id? owner)
    (raise-argument-error
     'storage-claim-issuance-work!
     "non-empty opaque owner identifier up to 256 characters"
     owner))
  (unless (exact-positive-integer? lease-seconds)
    (raise-argument-error
     'storage-claim-issuance-work! "exact-positive-integer?" lease-seconds))
  (check-timestamp 'storage-claim-issuance-work! now)
  (define item
    ((commerce-storage-issuance-claim storage) owner lease-seconds now))
  (when item
    (log-commerce-event!
     'info 'issuance-claimed
     (hash 'idempotency-key (issuance-outbox-item-idempotency-key item)
           'outbox-id (issuance-outbox-item-id item))
     (hash 'attempts (issuance-outbox-item-attempts item)
           'action (issuance-outbox-item-action item))))
  item)

;; Appends the lineage root with revision zero, or exactly one successor,
;; and completes the claimed work in one transaction. The claimed item
;; carries the lease owner that completion re-checks against the database.
;; When the caller also supplies the exact signed envelope bytes, the same
;; transaction records the issued credential and — with a one-time claim
;; token and expiry — its fulfillment claim; only the token's SHA-256
;; digest is ever stored.
(define (storage-complete-issuance-work! storage item
                                         #:issuer issuer
                                         #:subject-type subject-type
                                         #:entitlement-id entitlement-id
                                         #:credential-id credential-id
                                         #:policy-id policy-id
                                         #:policy-version policy-version
                                         #:payload-bytes payload-bytes
                                         #:issued-at issued-at
                                         #:recorded-at recorded-at
                                         #:signed-credential-bytes
                                         [signed-credential-bytes #f]
                                         #:key-id [key-id #f]
                                         #:claim-token [claim-token #f]
                                         #:claim-expires-at
                                         [claim-expires-at #f])
  (check-storage 'storage-complete-issuance-work! storage)
  (check-claimed-work 'storage-complete-issuance-work! item)
  (for ([label/value
        (in-list
         (list (list "issuer" issuer)
               (list "subject type" subject-type)
               (list "entitlement id" entitlement-id)
               (list "credential id" credential-id)
               (list "policy id" policy-id)))]
        #:unless (opaque-id? (second label/value)))
    (raise-argument-error
     'storage-complete-issuance-work!
     (format "non-empty opaque ~a up to 256 characters" (first label/value))
     (second label/value)))
  (unless (exact-positive-integer? policy-version)
    (raise-argument-error
     'storage-complete-issuance-work!
     "exact-positive-integer?" policy-version))
  (unless (and (bytes? payload-bytes) (> (bytes-length payload-bytes) 0))
    (raise-argument-error
     'storage-complete-issuance-work!
     "non-empty bytes?" payload-bytes))
  (unless (and (string? issued-at) (<= 1 (string-length issued-at) 512))
    (raise-argument-error
     'storage-complete-issuance-work!
     "non-empty Permit issued-at string up to 512 characters" issued-at))
  (check-timestamp 'storage-complete-issuance-work! recorded-at)
  (when signed-credential-bytes
    (unless (and (bytes? signed-credential-bytes)
                 (> (bytes-length signed-credential-bytes) 0))
      (raise-argument-error
       'storage-complete-issuance-work!
       "non-empty bytes?" signed-credential-bytes))
    (unless (opaque-id? key-id)
      (raise-argument-error
       'storage-complete-issuance-work!
       "non-empty opaque key id up to 256 characters" key-id)))
  (when claim-token
    (unless signed-credential-bytes
      (raise-argument-error
       'storage-complete-issuance-work!
       "signed credential bytes are required to record a claim"
       claim-token))
    (unless (and (string? claim-token)
                 (<= 1 (string-length claim-token) 512))
      (raise-argument-error
       'storage-complete-issuance-work!
       "non-empty claim token up to 512 characters" claim-token))
    (unless (exact-nonnegative-integer? claim-expires-at)
      (raise-argument-error
       'storage-complete-issuance-work!
       "exact-nonnegative-integer?" claim-expires-at)))
  (define completion
    ((commerce-storage-issuance-complete storage)
     item issuer subject-type entitlement-id credential-id policy-id
     policy-version (bytes->immutable-bytes payload-bytes) issued-at
     recorded-at
     (and signed-credential-bytes
          (bytes->immutable-bytes signed-credential-bytes))
     key-id claim-token claim-expires-at))
  (log-commerce-event!
   'info 'issuance-completed
   (hash 'idempotency-key (issuance-outbox-item-idempotency-key item)
         'entitlement-id entitlement-id
         'credential-id credential-id)
   (hash 'revision
         (entitlement-revision-revision
          (issuance-completion-revision completion))
         'delivered? (and signed-credential-bytes #t)))
  completion)

;; Returns transient work to 'pending with a typed error and a future retry
;; time. Only the lease owner may release, and the attempts counter is left
;; exactly as the claim incremented it.
(define (storage-release-issuance-work! storage item
                                        #:error-code error-code
                                        #:retry-at retry-at)
  (check-storage 'storage-release-issuance-work! storage)
  (check-claimed-work 'storage-release-issuance-work! item)
  (check-typed-code 'storage-release-issuance-work! error-code)
  (check-timestamp 'storage-release-issuance-work! retry-at)
  (define item-released
    ((commerce-storage-issuance-release storage) item error-code retry-at))
  (log-commerce-event!
   'info 'issuance-released
   (hash 'idempotency-key (issuance-outbox-item-idempotency-key item))
   (hash 'error-code error-code 'retry-at retry-at))
  item-released)

(define (storage-entitlement-ref storage entitlement-id)
  (check-storage 'storage-entitlement-ref storage)
  (unless (opaque-id? entitlement-id)
    (raise-argument-error
     'storage-entitlement-ref
     "non-empty opaque entitlement identifier" entitlement-id))
  ((commerce-storage-entitlement-lookup storage) entitlement-id))

(define (storage-lineage-ref storage
                             #:issuer issuer
                             #:subject-type subject-type
                             #:subject-id subject-id
                             #:offer-id offer-id)
  (check-storage 'storage-lineage-ref storage)
  (for ([label/value
         (in-list
          (list (list "issuer" issuer)
                (list "subject type" subject-type)
                (list "subject id" subject-id)
                (list "offer id" offer-id)))]
        #:unless (opaque-id? (second label/value)))
    (raise-argument-error
     'storage-lineage-ref
     (format "non-empty opaque ~a up to 256 characters" (first label/value))
     (second label/value)))
  ((commerce-storage-lineage-lookup storage)
   issuer subject-type subject-id offer-id))

(define (storage-entitlement-revision-ref storage entitlement-id revision)
  (check-storage 'storage-entitlement-revision-ref storage)
  (unless (opaque-id? entitlement-id)
    (raise-argument-error
     'storage-entitlement-revision-ref
     "non-empty opaque entitlement identifier" entitlement-id))
  (check-timestamp 'storage-entitlement-revision-ref revision)
  ((commerce-storage-revision-lookup storage) entitlement-id revision))

(define (storage-latest-entitlement-revision storage entitlement-id)
  (check-storage 'storage-latest-entitlement-revision storage)
  (unless (opaque-id? entitlement-id)
    (raise-argument-error
     'storage-latest-entitlement-revision
     "non-empty opaque entitlement identifier" entitlement-id))
  ((commerce-storage-latest-revision-lookup storage) entitlement-id))

;; The invariant behind hosted proof verification: entitlement freshness and
;; unresolved-refund state deny independently, so they must also be observed
;; together. A withdrawal committing between separate reads would combine a
;; pre-withdrawal revision with a post-withdrawal (already resolved) refund
;; check and serve the withdrawn grant. This reader returns both facts from
;; one consistent storage snapshot; callers must not re-read either fact
;; separately to make the decision.
(define (storage-latest-entitlement-revision-and-unresolved-refund
         storage entitlement-id subject-id offer-id)
  (check-storage
   'storage-latest-entitlement-revision-and-unresolved-refund storage)
  (for ([label/value
         (in-list
          (list (list "entitlement identifier" entitlement-id)
                (list "subject identifier" subject-id)
                (list "offer identifier" offer-id)))]
        #:unless (opaque-id? (second label/value)))
    (raise-argument-error
     'storage-latest-entitlement-revision-and-unresolved-refund
     (format "non-empty opaque ~a up to 256 characters" (first label/value))
     (second label/value)))
  (define snapshot
    ((commerce-storage-latest-revision-and-refund-lookup storage)
     entitlement-id subject-id offer-id))
  (values (vector-ref snapshot 0) (vector-ref snapshot 1)))

;; Fulfills a one-time claim: verifies the token, its state, and its window,
;; marks the claim fulfilled, and returns the exact signed envelope bytes.
;; Fulfillment never creates or changes a lineage revision.
(define (storage-claim-credential storage #:token token #:now now)
  (check-storage 'storage-claim-credential storage)
  (unless (and (string? token) (<= 1 (string-length token) 512))
    (raise-argument-error
     'storage-claim-credential
     "non-empty claim token up to 512 characters" token))
  (check-timestamp 'storage-claim-credential now)
  (define fulfillment
    (with-handlers
        ([exn:fail:commerce?
          (lambda (failure)
            (log-commerce-event!
             'warning 'claim-refused
             (hash)
             (hash 'code (exn:fail:commerce-code failure)))
            (raise failure))])
      ((commerce-storage-claim-lookup storage) token now)))
  (log-commerce-event!
   'info 'claim-fulfilled
   (hash 'claim-id (claim-fulfillment-claim-id fulfillment)
         'credential-id
         (issued-credential-record-credential-id
          (claim-fulfillment-credential fulfillment)))
   (hash))
  fulfillment)

;; Records that a delivery transport handed the claim token out. The first
;; notification timestamp wins; later retries are idempotent no-ops.
(define (storage-mark-claim-notified storage #:token token #:now now)
  (check-storage 'storage-mark-claim-notified storage)
  (unless (and (string? token) (<= 1 (string-length token) 512))
    (raise-argument-error
     'storage-mark-claim-notified
     "non-empty claim token up to 512 characters" token))
  (check-timestamp 'storage-mark-claim-notified now)
  ((commerce-storage-claim-notified storage) token now))

;; Operator enumeration: outbox rows in stable id order, optionally filtered
;; by status. Read-only, bounded by the caller.
(define (storage-outbox-scan storage #:status [status #f])
  (check-storage 'storage-outbox-scan storage)
  (when status
    (unless (member status '(pending processing completed))
      (raise-argument-error
       'storage-outbox-scan "(or/c 'pending 'processing 'completed #f)"
       status)))
  ((commerce-storage-outbox-scan storage) status))

(define (storage-order-journal storage provider order-id)
  (check-storage 'storage-order-journal storage)
  (unless (stable-id? provider)
    (raise-argument-error
     'storage-order-journal "stable kebab-case provider identifier" provider))
  (unless (opaque-id? order-id)
    (raise-argument-error
     'storage-order-journal
     "non-empty opaque provider order identifier" order-id))
  ((commerce-storage-order-journal storage) provider order-id))

;; Reads one journal row back by its durable sequence number. The issuer role
;; uses this to re-verify the exact evidence a claimed outbox row was derived
;; from; the sequence is immutable and never reused.
(define (storage-journal-sequence-ref storage sequence)
  (check-storage 'storage-journal-sequence-ref storage)
  (unless (exact-nonnegative-integer? sequence)
    (raise-argument-error
     'storage-journal-sequence-ref "exact-nonnegative-integer?" sequence))
  ((commerce-storage-journal-sequence-lookup storage) sequence))

(define (storage-order-outbox storage provider order-id)
  (check-storage 'storage-order-outbox storage)
  (unless (stable-id? provider)
    (raise-argument-error
     'storage-order-outbox "stable kebab-case provider identifier" provider))
  (unless (opaque-id? order-id)
    (raise-argument-error
     'storage-order-outbox
     "non-empty opaque provider order identifier" order-id))
  ((commerce-storage-order-outbox storage) provider order-id))

(define (storage-issued-credential-ref storage issuance-outbox-id)
  (check-storage 'storage-issued-credential-ref storage)
  (unless (exact-nonnegative-integer? issuance-outbox-id)
    (raise-argument-error
     'storage-issued-credential-ref
     "exact-nonnegative-integer?" issuance-outbox-id))
  ((commerce-storage-issued-credential-lookup storage) issuance-outbox-id))

;; Operator redrive: makes one pending row due immediately without touching
;; its attempts counter. In-flight and completed work is never rewound; the
;; journal remains the only replay source.
(define (storage-redrive-issuance-work! storage idempotency-key #:now now)
  (check-storage 'storage-redrive-issuance-work! storage)
  (unless (and (string? idempotency-key)
               (<= 1 (string-length idempotency-key) 512))
    (raise-argument-error
     'storage-redrive-issuance-work!
     "non-empty idempotency key up to 512 characters" idempotency-key))
  (check-timestamp 'storage-redrive-issuance-work! now)
  (define redriven
    ((commerce-storage-redrive storage) idempotency-key now))
  (log-commerce-event!
   'info 'issuance-redriven
   (hash 'idempotency-key idempotency-key
         'outbox-id (issuance-outbox-item-id redriven))
   (hash))
  redriven)

;; One read-only readiness snapshot for health endpoints and stuck-work
;; inspection. Counts share one query instant; nothing is mutated.
(define (storage-readiness storage #:now now)
  (check-storage 'storage-readiness storage)
  (check-timestamp 'storage-readiness now)
  ((commerce-storage-readiness storage) now))

;; Retention: transitions ready claims whose fulfillment window has passed
;; to the terminal expired state and returns how many rows retired. Deletion
;; of durable evidence is never part of this boundary.
(define (storage-retire-expired-claims! storage #:now now)
  (check-storage 'storage-retire-expired-claims! storage)
  (check-timestamp 'storage-retire-expired-claims! now)
  ((commerce-storage-retire-expired-claims storage) now))

;; Persists the server-side checkout expectation created with a checkout.
;; Bindings are append-only: the merchant external reference maps to one
;; product, Offer, subject, and exact money, and never mutates.
(define (storage-create-checkout-binding! storage binding #:created-at created-at)
  (check-storage 'storage-create-checkout-binding! storage)
  (unless (checkout-binding? binding)
    (raise-argument-error
     'storage-create-checkout-binding! "checkout-binding?" binding))
  (check-timestamp
   'storage-create-checkout-binding! created-at)
  ((commerce-storage-checkout-binding-create storage) binding created-at))

(define (storage-checkout-binding-ref storage merchant-external-id)
  (check-storage 'storage-checkout-binding-ref storage)
  (unless (and (string? merchant-external-id)
               (<= 1 (string-length merchant-external-id) 128))
    (raise-argument-error
     'storage-checkout-binding-ref
     "non-empty merchant external id up to 128 characters"
     merchant-external-id))
  ((commerce-storage-checkout-binding-lookup storage)
   merchant-external-id))

;; Appends one operator-action audit record and returns its id. Audit rows
;; are append-only evidence: what, by whom, why, on which subject.
(define (storage-append-audit! storage
                               #:action action
                               #:operator operator
                               #:reason reason
                               #:subject subject
                               #:created-at created-at)
  (check-storage 'storage-append-audit! storage)
  (for ([label/value
         (in-list
          (list (list "action" action)
                (list "operator" operator)
                (list "subject" subject)))]
        #:unless (and (string? (second label/value))
                      (<= 1 (string-length (second label/value)) 256)))
    (raise-argument-error
     'storage-append-audit!
     (format "non-empty ~a up to 256 characters" (first label/value))
     (second label/value)))
  (unless (and (string? reason)
               (<= 1 (string-length reason) 4096))
    (raise-argument-error
     'storage-append-audit!
     "non-empty reason up to 4096 characters" reason))
  (check-timestamp 'storage-append-audit! created-at)
  ((commerce-storage-audit-append storage)
   action operator reason subject created-at))

(define (storage-audit-scan storage #:action [action #f])
  (check-storage 'storage-audit-scan storage)
  (when action
    (unless (and (string? action) (<= 1 (string-length action) 128))
      (raise-argument-error
       'storage-audit-scan
       "non-empty action up to 128 characters or #f" action)))
  ((commerce-storage-audit-scan storage) action))

;; Operator reissue: a customer whose claim window passed receives a fresh
;; one-time claim for the SAME issued credential. Never creates a second
;; credential or lineage revision; always appends audit evidence.
(define (storage-reissue-claim! storage
                                #:claim-id claim-id
                                #:claim-token claim-token
                                #:expires-at expires-at
                                #:operator operator
                                #:reason reason
                                #:now now)
  (check-storage 'storage-reissue-claim! storage)
  (unless (exact-nonnegative-integer? claim-id)
    (raise-argument-error
     'storage-reissue-claim! "exact-nonnegative-integer?" claim-id))
  (unless (and (string? claim-token)
               (<= 1 (string-length claim-token) 512))
    (raise-argument-error
     'storage-reissue-claim!
     "non-empty claim token up to 512 characters" claim-token))
  (check-timestamp 'storage-reissue-claim! expires-at)
  (unless (and (string? operator) (<= 1 (string-length operator) 256))
    (raise-argument-error
     'storage-reissue-claim!
     "non-empty operator up to 256 characters" operator))
  (unless (and (string? reason) (<= 1 (string-length reason) 4096))
    (raise-argument-error
     'storage-reissue-claim!
     "non-empty reason up to 4096 characters" reason))
  (check-timestamp 'storage-reissue-claim! now)
  (define new-claim-id
    ((commerce-storage-reissue storage)
     claim-id claim-token expires-at operator reason now))
  (storage-claim-record-ref storage new-claim-id))

(define (storage-claim-record-ref storage claim-id)
  (check-storage 'storage-claim-record-ref storage)
  (unless (exact-nonnegative-integer? claim-id)
    (raise-argument-error
     'storage-claim-record-ref "exact-nonnegative-integer?" claim-id))
  ((commerce-storage-claim-record-lookup storage) claim-id))

;; An authenticated refund journal event must be reflected in a durable
;; signed withdrawal revision before a hosted service can serve an older grant.
;; The caller must also enforce its product/subject authorization boundary.
(define (storage-unresolved-refund? storage subject-id offer-id)
  (check-storage 'storage-unresolved-refund? storage)
  (unless (opaque-id? subject-id)
    (raise-argument-error 'storage-unresolved-refund?
                          "non-empty opaque subject identifier" subject-id))
  (unless (opaque-id? offer-id)
    (raise-argument-error 'storage-unresolved-refund?
                          "non-empty opaque Offer identifier" offer-id))
  ((commerce-storage-unresolved-refund storage) subject-id offer-id))

(define (storage-close storage)
  (check-storage 'storage-close storage)
  ((commerce-storage-close storage)))
