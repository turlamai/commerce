#lang racket/base

;; Server-side feature/edition/add-on/update admission over an authenticated,
;; current, signed Permit proof. This module is transport-neutral: callers
;; MUST authenticate service principals and bind their account/Offer/product
;; before supplying #:authorize. Never trust client-provided paid flags.
(provide current-hosted-right-admission)

(require permit/credential
         permit/envelope
         permit/policy
         permit/trust
         "hosted-proof.rkt")

(define (evaluate-right credential product-id kind right-id at published-at)
  (case kind
    [(feature)
     (feature-entitled? credential product-id right-id
                        #:at at #:published-at published-at)]
    [(edition)
     (edition-entitled? credential product-id right-id #:at at)]
    [(addon)
     (addon-entitled? credential product-id right-id #:at at)]
    [(update)
     (and published-at
          (update-entitled? credential product-id published-at #:at at))]
    [else #f]))

(define (current-hosted-right-admission storage
                                        #:issuer issuer
                                        #:subject-type subject-type
                                        #:subject-id subject-id
                                        #:offer-id offer-id
                                        #:product-id product-id
                                        #:right-kind kind
                                        #:right-id right-id
                                        #:authorize authorize
                                        #:trust-store trust-store
                                        #:at at
                                        #:published-at [published-at #f]
                                        #:minimum-revision [minimum #f]
                                        #:expected-entitlement-id [expected-id #f])
  (unless (memq kind '(feature edition addon update))
    (raise-argument-error 'current-hosted-right-admission
                          "(or/c 'feature 'edition 'addon 'update)" kind))
  (unless (and (string? right-id) (<= 1 (string-length right-id) 128))
    (raise-argument-error 'current-hosted-right-admission
                          "non-empty right identifier up to 128 characters"
                          right-id))
  (unless (or (not published-at)
              (and (string? published-at) (<= 1 (string-length published-at) 64)))
    (raise-argument-error 'current-hosted-right-admission
                          "(or/c #f RFC3339-UTC-string)" published-at))
  ;; The Permit evaluator requires an immutable publication timestamp to
  ;; authorize a future feature stream or update. Missing is never allowed.
  (define proof
    (current-verified-entitlement-proof
     storage #:issuer issuer #:subject-type subject-type
     #:subject-id subject-id #:offer-id offer-id #:product-id product-id
     #:authorize authorize #:trust-store trust-store #:at at
     #:minimum-revision minimum
     #:expected-entitlement-id expected-id))
  (define proof-status (hash-ref proof 'status))
  (if (not (equal? proof-status "verified-proof"))
      (hasheq 'allowed #f 'status proof-status)
      ;; Reverify the returned signature against the same pinned trust store
      ;; before applying Permit policy. Policy rejects default to no access
      ;; and do not echo signed claims, PII or payment metadata.
      (with-handlers ([exn:fail?
                       (lambda (_) (hasheq 'allowed #f
                                            'status "policy-invalid"))])
        (let* ([envelope (jsexpr->envelope (hash-ref proof 'credential))]
               [credential (verify-credential envelope trust-store)]
               [allowed?
                (and (or (not (eq? kind 'update)) published-at)
                     (evaluate-right credential product-id kind right-id
                                     at published-at))])
          (if allowed?
              (hasheq 'allowed #t
                      'status "entitled"
                      'entitlement_id (hash-ref proof 'entitlement_id)
                      'revision (hash-ref proof 'revision))
              (hasheq 'allowed #f 'status "not-entitled"))))))
