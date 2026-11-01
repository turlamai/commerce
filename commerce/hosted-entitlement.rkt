#lang racket/base

;; Internal, scoped ledger lookup. A trusted caller must authenticate its
;; service identity and authorize the complete subject/Offer tuple first.
;; Ledger records are NOT proof of an effective or verified Permit grant.
(provide current-entitlement-snapshot)

(require "storage.rkt")

(define (current-entitlement-snapshot storage
                                     #:issuer issuer
                                     #:subject-type subject-type
                                     #:subject-id subject-id
                                     #:offer-id offer-id
                                     #:authorize authorize
                                     #:minimum-revision [minimum-revision #f]
                                     #:expected-entitlement-id
                                     [expected-entitlement-id #f])
  (unless (commerce-storage? storage)
    (raise-argument-error 'current-entitlement-snapshot
                          "commerce-storage?" storage))
  (unless (and (procedure? authorize)
               (procedure-arity-includes? authorize 4))
    (raise-argument-error 'current-entitlement-snapshot
                          "procedure accepting issuer, subject-type, subject-id, offer-id"
                          authorize))
  (unless (or (not minimum-revision)
              (exact-nonnegative-integer? minimum-revision))
    (raise-argument-error 'current-entitlement-snapshot
                          "(or/c #f exact-nonnegative-integer?)"
                          minimum-revision))
  (unless (or (not expected-entitlement-id)
              (and (string? expected-entitlement-id)
                   (<= 1 (string-length expected-entitlement-id) 256)))
    (raise-argument-error 'current-entitlement-snapshot
                          "(or/c #f non-empty-entitlement-id-string)"
                          expected-entitlement-id))
  ;; Literal #t is required. Denial precedes any storage/existence lookup.
  (unless (eq? #t (authorize issuer subject-type subject-id offer-id))
    (error 'current-entitlement-snapshot "access denied"))
  (define lineage
    (storage-lineage-ref storage
                         #:issuer issuer #:subject-type subject-type
                         #:subject-id subject-id #:offer-id offer-id))
  (cond
    [(not lineage)
     (hasheq 'status
             (cond [expected-entitlement-id "lineage-mismatch"]
                   [minimum-revision "stale-revision"]
                   [else "absent"]))]
    [(and expected-entitlement-id
          (not (equal? expected-entitlement-id
                       (entitlement-lineage-entitlement-id lineage))))
     ;; Refuse a new identity even if its numeric revision looks fresh.
     (hasheq 'status "lineage-mismatch")]
    [else
     (let ([revision
            (storage-latest-entitlement-revision
             storage (entitlement-lineage-entitlement-id lineage))])
       (cond
         [(and minimum-revision
               (or (not revision)
                   (< (entitlement-revision-revision revision)
                      minimum-revision)))
          (hasheq 'status "stale-revision")]
         [(not revision) (hasheq 'status "pending")]
         [else
          (let ([action (entitlement-revision-action revision)])
            (hasheq
             'status
             (cond [(eq? action 'grant) "recorded-grant"]
                   [(eq? action 'withdraw) "recorded-withdrawal"]
                   [else "unknown"])
             'entitlement_id (entitlement-lineage-entitlement-id lineage)
             'revision (entitlement-revision-revision revision)
             'credential_id (entitlement-revision-credential-id revision)
             'action (symbol->string action)
             'policy_id (entitlement-revision-policy-id revision)
             'policy_version (entitlement-revision-policy-version revision)
             'recorded_at (entitlement-revision-recorded-at revision)))]))]))
