#lang racket/base

(provide
 permit-grant-policy?
 make-permit-grant-policy
 permit-grant-policy-products
 permit-grant-policy-product-families
 permit-grant-policy-edition
 permit-grant-policy-feature-policy
 permit-grant-policy-features
 permit-grant-policy-addons
 permit-grant-policy-capabilities
 permit-constraints-policy?
 make-permit-constraints-policy
 permit-constraints-policy-use-expires-at
 permit-constraints-policy-updates-through
 permit-constraints-policy-updates-through-duration-days
 permit-constraints-policy-features-through
 permit-constraints-policy-version-min
 permit-constraints-policy-version-max
 permit-constraints-policy-named-seats
 permit-constraints-policy-device-activations
 permit-constraints-policy-concurrent-seats
 permit-constraints-policy-installation-id
 permit-constraints-policy-activation-required?
 permit-entitlement-policy?
 make-permit-entitlement-policy
 permit-entitlement-policy-id
 permit-entitlement-policy-version
 permit-entitlement-policy-subject-type
 permit-entitlement-policy-grants
 permit-entitlement-policy-constraints
 permit-entitlement-policy-withdrawal-mode
 permit-policy-catalog?
 make-permit-policy-catalog
 permit-snapshot-request?
 permit-snapshot-request-policy-id
 permit-snapshot-request-policy-version
 permit-snapshot-request-action
 permit-snapshot-request-source-idempotency-key
 permit-snapshot-request-payload
 permit-snapshot-request-payload-bytes
 permit-policy-for-offer
 permit-catalog-offer
 prepare-permit-snapshot)

(require permit/issuer
         racket/list
         racket/match
         "private/model.rkt"
         "private/permit-model.rkt"
         "private/time.rkt")

(define max-protocol-integer 9223372036854775807)
(define validation-time "2026-01-01T00:00:00Z")

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (null-if-false value)
  (if value value 'null))

(define (immutable-string-list values)
  (for/list ([value (in-list values)])
    (if (string? value) (string->immutable-string value) value)))

(define (immutable-capabilities values)
  (for/hasheq ([(key value) (in-hash values)])
    (values key (immutable-jsexpr value))))

(define (immutable-if-string value)
  (if (string? value) (string->immutable-string value) value))

;; Permit signs exact serialized bytes. A deep immutable copy prevents caller
;; mutation of inherited lineage containers or strings from making the exposed
;; payload disagree with the bytes returned beside it.
(define (immutable-jsexpr value)
  (cond
    [(string? value) (string->immutable-string value)]
    [(hash? value)
     (for/hasheq ([(key item) (in-hash value)])
       (values (immutable-jsexpr key) (immutable-jsexpr item)))]
    [(list? value)
     (for/list ([item (in-list value)])
       (immutable-jsexpr item))]
    [else value]))

(define (policy-validation-failure component policy-id _failure)
  (raise-commerce
   'invalid-entitlement-policy
   "Permit entitlement policy is invalid"
   (hash 'component component
         'policy-id policy-id)))

(define (with-policy-validation component policy-id thunk)
  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (policy-validation-failure
                      component policy-id failure))])
    (thunk)))

(define (grant-policy->permit policy)
  (grant
   #:products (permit-grant-policy-products policy)
   #:product-families (permit-grant-policy-product-families policy)
   #:edition (null-if-false (permit-grant-policy-edition policy))
   #:feature-policy
   (symbol->string (permit-grant-policy-feature-policy policy))
   #:features (permit-grant-policy-features policy)
   #:addons (permit-grant-policy-addons policy)
   #:capabilities (permit-grant-policy-capabilities policy)))

(define (constraints-policy->permit policy)
  (constraints
   #:use-expires-at
   (null-if-false (permit-constraints-policy-use-expires-at policy))
   #:updates-through
   (null-if-false (permit-constraints-policy-updates-through policy))
   #:features-through
   (null-if-false (permit-constraints-policy-features-through policy))
   #:version-min
   (null-if-false (permit-constraints-policy-version-min policy))
   #:version-max
   (null-if-false (permit-constraints-policy-version-max policy))
   #:named-seats
   (null-if-false (permit-constraints-policy-named-seats policy))
   #:device-activations
   (null-if-false (permit-constraints-policy-device-activations policy))
   #:concurrent-seats
   (null-if-false (permit-constraints-policy-concurrent-seats policy))
   #:installation-id
   (null-if-false (permit-constraints-policy-installation-id policy))
   #:activation-required?
   (permit-constraints-policy-activation-required? policy)))

(define (validate-snapshot-shape subject-value grants-value constraints-value)
  (entitlement-payload
   #:issuer "commerce-policy-validation"
   #:credential-id "commerce-policy-validation-credential"
   #:entitlement-id "commerce-policy-validation-entitlement"
   #:subject subject-value
   #:grants grants-value
   #:constraints constraints-value
   #:issued-at validation-time))

(define (make-permit-grant-policy
         #:products [products '()]
         #:product-families [product-families '()]
         #:edition [edition #f]
         #:feature-policy [feature-policy 'explicit]
         #:features [features '()]
         #:addons [addons '()]
         #:capabilities [capabilities (hasheq)])
  (with-policy-validation
   'grant #f
   (lambda ()
     (define candidate
       (permit-grant-policy
        (immutable-string-list products)
        (immutable-string-list product-families)
        (immutable-if-string edition)
        feature-policy
        (immutable-string-list features)
        (immutable-string-list addons)
        (immutable-capabilities capabilities)))
     (validate-snapshot-shape
      (subject #:type "person" #:id "commerce-policy-validation-subject")
      (list (grant-policy->permit candidate))
      (constraints))
     candidate)))

(define (make-permit-constraints-policy
         #:use-expires-at [use-expires-at #f]
         #:updates-through [updates-through #f]
         #:updates-through-duration-days [updates-through-duration-days #f]
         #:features-through [features-through #f]
         #:version-min [version-min #f]
         #:version-max [version-max #f]
         #:named-seats [named-seats #f]
         #:device-activations [device-activations #f]
         #:concurrent-seats [concurrent-seats #f]
         #:installation-id [installation-id #f]
         #:activation-required? [activation-required? #f])
  (unless (or (not updates-through-duration-days)
              (exact-positive-integer? updates-through-duration-days))
    (raise-argument-error
     'make-permit-constraints-policy
     "(or/c #f exact-positive-integer?) updates-through-duration-days"
     updates-through-duration-days))
  ;; A policy states the updates window one way: a fixed publication
  ;; instant for every credential under the policy, or a duration from the
  ;; order's paid evidence computed at issuance. Both at once would make
  ;; two credentials under one policy id carry different window semantics.
  (when (and updates-through updates-through-duration-days)
    (raise-argument-error
     'make-permit-constraints-policy
     "#:updates-through and #:updates-through-duration-days are mutually exclusive"
     updates-through))
  (with-policy-validation
   'constraints #f
   (lambda ()
     (define candidate
       (permit-constraints-policy
        (immutable-if-string use-expires-at)
        (immutable-if-string updates-through)
        (immutable-if-string features-through)
        (immutable-if-string version-min)
        (immutable-if-string version-max)
        named-seats device-activations concurrent-seats
        (immutable-if-string installation-id)
        activation-required?
        updates-through-duration-days))
     (validate-snapshot-shape
      (subject #:type "person" #:id "commerce-policy-validation-subject")
      (list (grant #:products '("commerce-policy-validation-product")))
      (constraints-policy->permit candidate))
     candidate)))

(define (make-permit-entitlement-policy
         id version
         #:subject-type subject-type
         #:grants grants-value
         #:constraints
         [constraints-value (make-permit-constraints-policy)]
         #:withdrawal-mode [withdrawal-mode 'expire-at-issuance])
  (unless (stable-id? id)
    (raise-argument-error
     'make-permit-entitlement-policy
     "stable kebab-case policy identifier"
     id))
  (unless (and (exact-positive-integer? version)
               (<= version max-protocol-integer))
    (raise-argument-error
     'make-permit-entitlement-policy
     "positive signed 64-bit integer policy version"
     version))
  (unless (and (list? grants-value)
               (andmap permit-grant-policy? grants-value))
    (raise-argument-error
     'make-permit-entitlement-policy
     "(listof permit-grant-policy?)"
     grants-value))
  (unless (permit-constraints-policy? constraints-value)
    (raise-argument-error
     'make-permit-entitlement-policy
     "permit-constraints-policy?"
     constraints-value))
  (unless (eq? withdrawal-mode 'expire-at-issuance)
    (raise-argument-error
     'make-permit-entitlement-policy
     "'expire-at-issuance"
     withdrawal-mode))
  (with-policy-validation
   'policy id
   (lambda ()
     (validate-snapshot-shape
      (subject #:type (symbol->string subject-type)
               #:id "commerce-policy-validation-subject")
      (map grant-policy->permit grants-value)
      (constraints-policy->permit constraints-value))
     (permit-entitlement-policy
      (string->immutable-string id)
      version subject-type (append grants-value '()) constraints-value
      withdrawal-mode))))

(define (insert-unique! values id-of code description)
  (for/fold ([by-id (hash)]) ([value (in-list values)])
    (define id (id-of value))
    (when (hash-has-key? by-id id)
      (raise-commerce code description (hash 'id id)))
    (hash-set by-id id value)))

(define (policy-explicit-products policy)
  (remove-duplicates
   (append-map permit-grant-policy-products
               (permit-entitlement-policy-grants policy))
   string=?))

(define (make-permit-policy-catalog
         offers policies
         #:deleted-offer-ids [deleted-offer-ids '()])
  (unless (and (list? offers) (andmap offer? offers))
    (raise-argument-error
     'make-permit-policy-catalog "(listof offer?)" offers))
  (unless (and (list? policies)
               (andmap permit-entitlement-policy? policies))
    (raise-argument-error
     'make-permit-policy-catalog
     "(listof permit-entitlement-policy?)"
     policies))
  (unless (and (list? deleted-offer-ids)
               (andmap stable-id? deleted-offer-ids))
    (raise-argument-error
     'make-permit-policy-catalog
     "(listof stable kebab-case offer identifiers)"
     deleted-offer-ids))
  (define immutable-offers
    (for/list ([candidate (in-list offers)])
      (offer
       (string->immutable-string (offer-id candidate))
       (string->immutable-string (offer-product-id candidate))
       (offer-kind candidate)
       (money
        (string->immutable-string
         (money-currency (offer-price candidate)))
        (money-minor-units (offer-price candidate)))
       (string->immutable-string
        (offer-entitlement-policy-id candidate)))))
  (define offers-by-id
    (insert-unique!
     immutable-offers offer-id
     'invalid-policy-catalog "duplicate Offer id in Permit policy catalog"))
  (define policies-by-id
    (insert-unique!
     policies permit-entitlement-policy-id
     'invalid-policy-catalog "duplicate Permit policy id in catalog"))
  (define deleted-set
    (for/fold ([ids (hash)]) ([given-id (in-list deleted-offer-ids)])
      (define id (string->immutable-string given-id))
      (when (or (hash-has-key? ids id)
                (hash-has-key? offers-by-id id))
        (raise-commerce
         'invalid-policy-catalog
         "deleted Offer tombstone conflicts with policy catalog"
         (hash 'offer-id id)))
      (hash-set ids id #t)))
  (for ([candidate (in-list immutable-offers)])
    (define policy-id (offer-entitlement-policy-id candidate))
    (define policy (hash-ref policies-by-id policy-id #f))
    (unless policy
      (raise-commerce
       'unknown-entitlement-policy
       "Offer references an unknown Permit entitlement policy"
       (hash 'offer-id (offer-id candidate) 'policy-id policy-id)))
    (unless (member (offer-product-id candidate)
                    (policy-explicit-products policy)
                    string=?)
      (raise-commerce
       'policy-offer-mismatch
       "Permit policy does not grant the Offer product"
       (hash 'offer-id (offer-id candidate)
             'policy-id policy-id
             'product-id (offer-product-id candidate)))))
  (permit-policy-catalog offers-by-id policies-by-id deleted-set))

(define (check-request-string who label value)
  (unless (opaque-id? value)
    (raise-argument-error who (format "non-empty ~a up to 256 characters" label)
                          value)))

(define (make-initial-snapshot policy intent issuer credential-id
                               entitlement-id issued-at)
  (with-handlers
      ([exn:fail?
        (lambda (_failure)
          (raise-commerce
           'invalid-entitlement-request
           "Permit snapshot request metadata is invalid"
           (hash 'policy-id (permit-entitlement-policy-id policy)
                 'source-idempotency-key
                 (rights-intent-idempotency-key intent))))])
    (entitlement-payload
     #:issuer issuer
     #:credential-id credential-id
     #:entitlement-id entitlement-id
     #:subject
     (subject
      #:type
      (symbol->string (permit-entitlement-policy-subject-type policy))
      #:id (rights-intent-subject-id intent))
     #:grants
     (map grant-policy->permit (permit-entitlement-policy-grants policy))
     #:constraints
     (constraints-policy->permit
      (permit-entitlement-policy-constraints policy))
     #:issued-at issued-at)))

(define (lineage-matches? previous policy intent issuer entitlement-id)
  (define expected-subject-type
    (symbol->string (permit-entitlement-policy-subject-type policy)))
  (define expected-grants
    (map grant-policy->permit (permit-entitlement-policy-grants policy)))
  (with-handlers ([exn:fail? (lambda (_failure) #f)])
    (define previous-subject (hash-ref previous 'subject))
    (and (equal? (hash-ref previous 'type) "entitlement")
         (equal? (hash-ref previous 'issuer) issuer)
         (equal? (hash-ref previous 'entitlement_id) entitlement-id)
         (equal? (hash-ref previous-subject 'type) expected-subject-type)
         (equal? (hash-ref previous-subject 'id)
                 (rights-intent-subject-id intent))
         (equal? (hash-ref previous 'grants) expected-grants))))

(define (make-successor-snapshot policy intent issuer credential-id
                                 entitlement-id issued-at previous
                                 use-expires-at)
  (unless (hash? previous)
    (raise-commerce
     'entitlement-lineage-conflict
     "successor lineage is not a complete Permit snapshot"
     (hash 'policy-id (permit-entitlement-policy-id policy)
           'source-idempotency-key
           (rights-intent-idempotency-key intent))))
  (unless (lineage-matches? previous policy intent issuer entitlement-id)
    (raise-commerce
     'entitlement-lineage-conflict
     "successor lineage does not match Offer, issuer, entitlement, or subject"
     (hash 'policy-id (permit-entitlement-policy-id policy)
           'source-idempotency-key
           (rights-intent-idempotency-key intent))))
  (with-handlers
      ([exn:fail?
        (lambda (_failure)
          (raise-commerce
           'entitlement-lineage-conflict
           "successor lineage cannot produce a Permit successor"
           (hash 'policy-id (permit-entitlement-policy-id policy)
                 'source-idempotency-key
                 (rights-intent-idempotency-key intent))))])
    (define previous-constraints (hash-ref previous 'constraints))
    (successor-payload
     previous
     #:credential-id credential-id
     #:issued-at issued-at
     #:constraints
     (hash-set previous-constraints 'use_expires_at use-expires-at))))

(define (resolve-policy catalog intent)
  (permit-policy-for-offer
   catalog (rights-intent-offer-id intent)))

;; Resolves the pinned policy for one Offer with the same typed failures as
;; snapshot preparation, so workers can fail before signing.
(define (permit-policy-for-offer catalog offer-id)
  (unless (permit-policy-catalog? catalog)
    (raise-argument-error
     'permit-policy-for-offer "permit-policy-catalog?" catalog))
  (unless (stable-id? offer-id)
    (raise-argument-error
     'permit-policy-for-offer "stable kebab-case offer identifier" offer-id))
  (when (hash-has-key? (permit-policy-catalog-deleted-offer-ids catalog)
                       offer-id)
    (raise-commerce
     'offer-deleted
     "rights intent references a deliberately deleted Offer"
     (hash 'offer-id offer-id)))
  (define resolved-offer
    (hash-ref (permit-policy-catalog-offers-by-id catalog)
              offer-id #f))
  (unless resolved-offer
    (raise-commerce
     'unknown-offer
     "rights intent references an unknown Offer"
     (hash 'offer-id offer-id)))
  (hash-ref (permit-policy-catalog-policies-by-id catalog)
            (offer-entitlement-policy-id resolved-offer)))

;; Resolves the pinned catalog Offer for an identifier without the policy
;; lookup: #f for unknown or deliberately deleted Offers. The issuer-side
;; evidence verifier uses the returned price as the amount trust anchor, so
;; a grant can never be induced for an amount the catalog never sold.
(define (permit-catalog-offer catalog offer-id)
  (unless (permit-policy-catalog? catalog)
    (raise-argument-error
     'permit-catalog-offer "permit-policy-catalog?" catalog))
  (unless (stable-id? offer-id)
    (raise-argument-error
     'permit-catalog-offer "stable kebab-case offer identifier" offer-id))
  (and (not (hash-has-key?
             (permit-policy-catalog-deleted-offer-ids catalog) offer-id))
       (hash-ref (permit-policy-catalog-offers-by-id catalog) offer-id #f)))

;; A duration policy pins the updates window to paid evidence: paid-at plus
;; the policy's days, derived deterministically so a replay converges on
;; the same window. Returns the snapshot with the derived updates_through,
;; #f when the policy carries no duration. Successors never recompute: the
;; window a revision was sold with is part of its lineage record.
(define (apply-updates-through-duration! policy snapshot paid-at intent)
  (define duration
    (permit-constraints-policy-updates-through-duration-days
     (permit-entitlement-policy-constraints policy)))
  (cond
    [(not duration) #f]
    [(not paid-at)
     (raise-commerce
      'order-paid-evidence-required
      "policy pins the updates window to paid evidence, but the order carries no paid-at"
      (hash 'policy-id (permit-entitlement-policy-id policy)
            'source-idempotency-key
            (rights-intent-idempotency-key intent)))]
    [else
     (hash-set snapshot
               'constraints
               (hash-set (hash-ref snapshot 'constraints)
                         'updates_through
                         (epoch-seconds->rfc3339
                          (+ paid-at (* duration 86400)))))]))

(define (prepare-permit-snapshot
         catalog intent
         #:issuer issuer
         #:credential-id credential-id
         #:entitlement-id entitlement-id
         #:issued-at issued-at
         #:previous [previous #f]
         #:use-expires-at [use-expires-at #f]
         #:paid-at [paid-at #f])
  (unless (permit-policy-catalog? catalog)
    (raise-argument-error
     'prepare-permit-snapshot "permit-policy-catalog?" catalog))
  (unless (rights-intent? intent)
    (raise-argument-error 'prepare-permit-snapshot "rights-intent?" intent))
  (check-request-string 'prepare-permit-snapshot "issuer" issuer)
  (check-request-string 'prepare-permit-snapshot "credential id" credential-id)
  (check-request-string 'prepare-permit-snapshot "entitlement id" entitlement-id)
  (unless (string? issued-at)
    (raise-argument-error 'prepare-permit-snapshot "string? issued-at" issued-at))
  (unless (or (not paid-at) (exact-positive-integer? paid-at))
    (raise-argument-error
     'prepare-permit-snapshot "(or/c #f exact-positive-integer?) paid-at" paid-at))
  (define policy (resolve-policy catalog intent))
  (define initial
    (make-initial-snapshot policy intent issuer credential-id
                           entitlement-id issued-at))
  (define action (rights-intent-action intent))
  (define snapshot
    (match action
      ['grant
       (when previous
         (raise-commerce
          'entitlement-lineage-conflict
          "initial one-time grant cannot replace an existing lineage"
          (hash 'policy-id (permit-entitlement-policy-id policy)
                'source-idempotency-key
                (rights-intent-idempotency-key intent))))
       (or (apply-updates-through-duration! policy initial paid-at intent)
           initial)]
      ['withdraw
       (unless previous
         (raise-commerce
          'entitlement-lineage-required
          "withdrawal requires the previous complete entitlement snapshot"
          (hash 'policy-id (permit-entitlement-policy-id policy)
                'source-idempotency-key
                (rights-intent-idempotency-key intent))))
       (make-successor-snapshot
        policy intent issuer credential-id entitlement-id issued-at previous
        (or use-expires-at issued-at))]
      ['renew
       (unless previous
         (raise-commerce
          'entitlement-lineage-required
          "renewal requires the previous complete entitlement snapshot"
          (hash 'policy-id (permit-entitlement-policy-id policy)
                'source-idempotency-key
                (rights-intent-idempotency-key intent))))
       (unless (string? use-expires-at)
         (raise-commerce
          'invalid-entitlement-request
          "renewal requires the paid-through use-expiry"
          (hash 'policy-id (permit-entitlement-policy-id policy)
                'source-idempotency-key
                (rights-intent-idempotency-key intent))))
       (make-successor-snapshot
        policy intent issuer credential-id entitlement-id issued-at previous
        use-expires-at)]
      [_
       (raise-commerce
        'unsupported-rights-action
        "Permit policy mapping does not support the rights action"
        (hash 'action action
              'source-idempotency-key
              (rights-intent-idempotency-key intent)))]))
  (define-values (immutable-snapshot immutable-payload-bytes)
    (with-handlers
        ([exn:fail?
          (lambda (_failure)
            (raise-commerce
             (if (eq? action 'withdraw)
                 'entitlement-lineage-conflict
                 'invalid-entitlement-request)
             "Permit snapshot cannot be serialized as exact JSON bytes"
             (hash 'policy-id (permit-entitlement-policy-id policy)
                   'source-idempotency-key
                   (rights-intent-idempotency-key intent))))])
      (define frozen (immutable-jsexpr snapshot))
      (values frozen
              (bytes->immutable-bytes (payload->bytes frozen)))))
  (permit-snapshot-request
   (permit-entitlement-policy-id policy)
   (permit-entitlement-policy-version policy)
   action
   (string->immutable-string (rights-intent-idempotency-key intent))
   immutable-snapshot
   immutable-payload-bytes))
