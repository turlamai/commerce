#lang racket/base

;; Server-to-server read boundary for one exact subject and Offer.
;; Not an HTTP route: callers must authenticate and authorize their service
;; identity before invoking this function. No client-provided paid flag.
;; Recorded revision metadata is never proof of a cryptographically valid
;; credential or the current effective permission of a service account.
(provide current-entitlement-snapshot)

(require "storage.rkt")

(define (current-entitlement-snapshot storage
                                     #:issuer issuer
                                     #:subject-type subject-type
                                     #:subject-id subject-id
                                     #:offer-id offer-id
                                     #:authorize authorize)
  (unless (commerce-storage? storage)
    (raise-argument-error 'current-entitlement-snapshot "commerce-storage?" storage))
  (unless (procedure-arity-includes? authorize 4)
    (raise-argument-error 'current-entitlement-snapshot
                          "procedure accepting issuer, subject-type, subject-id, offer-id"
                          authorize))
  ;; Authorize the full scope before revealing existence, metadata or errors.
  (unless (eq? #t (authorize issuer subject-type subject-id offer-id))
    (error 'current-entitlement-snapshot "access denied"))
  (define lineage
    (storage-lineage-ref storage
                         #:issuer issuer #:subject-type subject-type
                         #:subject-id subject-id #:offer-id offer-id))
  (if (not lineage)
      (hasheq 'status "absent")
      (let ([revision
             (storage-latest-entitlement-revision
              storage (entitlement-lineage-entitlement-id lineage))])
        (cond
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
                   'policy_version (entitlement-revision-policy-version revision))]))))
