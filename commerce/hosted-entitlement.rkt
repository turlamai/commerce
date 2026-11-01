#lang racket/base

;; Scoped server-side ledger lookup. The caller MUST authenticate a service
;; principal and authorize the issuer + subject type/id + Offer before calling.
;; This module is not an HTTP authentication layer or a signed Permit verifier.
;; A recorded grant is not proof that effective rights are currently valid.
(provide current-entitlement-snapshot)

(require "storage.rkt")

(define (current-entitlement-snapshot storage
                                     #:issuer issuer
                                     #:subject-type subject-type
                                     #:subject-id subject-id
                                     #:offer-id offer-id
                                     #:authorize authorize
                                     #:minimum-revision [minimum-revision #f])
  (unless (commerce-storage? storage)
    (raise-argument-error 'current-entitlement-snapshot "commerce-storage?" storage))
  (unless (and (procedure? authorize) (procedure-arity-includes? authorize 4))
    (raise-argument-error 'current-entitlement-snapshot
                          "procedure accepting issuer, subject-type, subject-id, offer-id"
                          authorize))
  (unless (or (not minimum-revision)
              (exact-nonnegative-integer? minimum-revision))
    (raise-argument-error 'current-entitlement-snapshot
                          "(or/c #f exact-nonnegative-integer?)"
                          minimum-revision))
  ;; Fail before any subject/Offer lookup, including existence checks.
  (unless (eq? #t (authorize issuer subject-type subject-id offer-id))
    (error 'current-entitlement-snapshot "access denied"))
  (define lineage
    (storage-lineage-ref storage
                         #:issuer issuer #:subject-type subject-type
                         #:subject-id subject-id #:offer-id offer-id))
  (cond
    [(not lineage)
     (hasheq 'status (if minimum-revision "stale-revision" "absent"))]
    [else
     (define revision
       (storage-latest-entitlement-revision
        storage (entitlement-lineage-entitlement-id lineage)))
     (cond
       [(or (and minimum-revision
                 (or (not revision)
                     (< (entitlement-revision-revision revision)
                        minimum-revision))))
        ;; The caller has already observed a newer revision. An absent or
        ;; older replica must not be interpreted as a fresh grant.
        (hasheq 'status "stale-revision")]
       [(not revision) (hasheq 'status "pending")]
       [else
        (define action (entitlement-revision-action revision))
        (hasheq 'status
                (cond [(eq? action 'grant) "recorded-grant"]
                      [(eq? action 'withdraw) "recorded-withdrawal"]
                      [else "unknown"])
                'entitlement_id (entitlement-lineage-entitlement-id lineage)
                'revision (entitlement-revision-revision revision)
                'credential_id (entitlement-revision-credential-id revision)
                'action (symbol->string action)
                'policy_id (entitlement-revision-policy-id revision)
                'policy_version (entitlement-revision-policy-version revision)
                'recorded_at (entitlement-revision-recorded-at revision))])]))
