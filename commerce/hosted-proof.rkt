#lang racket/base

;; Read-only, scoped verification of the exact signed Permit evidence that
;; backs the latest Commerce ledger revision. Not an HTTP authentication layer.
;; A service must authenticate its principal and bind subject/Offer/product.
(provide current-verified-entitlement-proof)

(require permit/credential
         permit/envelope
         permit/policy
         permit/trust
         "hosted-entitlement.rkt"
         "storage.rkt")

(define (product-in-signed-grants? credential product-id)
  (for/or ([grant (in-list
                   (hash-ref (verified-credential-claims credential)
                             'grants))])
    (define scope (hash-ref grant 'scope))
    (and (member product-id (hash-ref scope 'products)) #t)))

(define (same-identity-and-bytes? credential record revision
                                  issuer subject-type subject-id)
  (and
   (equal? (verified-credential-type credential) "entitlement")
   (equal? (verified-credential-issuer credential) issuer)
   (equal? (verified-credential-subject-type credential) subject-type)
   (equal? (verified-credential-subject-id credential) subject-id)
   (equal? (verified-credential-entitlement-id credential)
           (entitlement-revision-entitlement-id revision))
   (equal? (verified-credential-revision credential)
           (entitlement-revision-revision revision))
   (equal? (verified-credential-id credential)
           (entitlement-revision-credential-id revision))
   (equal? (verified-credential-id credential)
           (issued-credential-record-credential-id record))
   (equal? (verified-credential-entitlement-id credential)
           (issued-credential-record-entitlement-id record))
   (equal? (verified-credential-revision credential)
           (issued-credential-record-revision record))
   (equal? (verified-credential-key-id credential)
           (issued-credential-record-key-id record))
   (equal? (verified-credential-issued-at credential)
           (entitlement-revision-issued-at revision))
   (bytes=? (verified-credential-payload credential)
            (entitlement-revision-payload-bytes revision))))

(define (current-verified-entitlement-proof storage
                                            #:issuer issuer
                                            #:subject-type subject-type
                                            #:subject-id subject-id
                                            #:offer-id offer-id
                                            #:product-id product-id
                                            #:authorize authorize
                                            #:trust-store trust-store
                                            #:at at
                                            #:minimum-revision [minimum #f]
                                            #:expected-entitlement-id
                                            [expected-id #f])
  (unless (trust-store? trust-store)
    (raise-argument-error 'current-verified-entitlement-proof
                          "trust-store?" trust-store))
  (unless (and (string? product-id) (<= 1 (string-length product-id) 96))
    (raise-argument-error 'current-verified-entitlement-proof
                          "non-empty product id up to 96 characters"
                          product-id))
  (unless (and (string? at) (<= 1 (string-length at) 64))
    (raise-argument-error 'current-verified-entitlement-proof
                          "RFC 3339 UTC time string" at))
  ;; The existing read primitive denies unauthorized scopes *before* lookup.
  (define snapshot
    (current-entitlement-snapshot
     storage
     #:issuer issuer #:subject-type subject-type #:subject-id subject-id
     #:offer-id offer-id #:authorize authorize
     #:minimum-revision minimum #:expected-entitlement-id expected-id))
  (define status (hash-ref snapshot 'status))
  (if (not (equal? status "recorded-grant"))
      ;; Explicitly do not promote a ledger-only withdrawal, absent, pending,
      ;; stale, or changed-lineage status into a signed entitlement.
      snapshot
      (let ([revision
             (storage-latest-entitlement-revision
              storage (hash-ref snapshot 'entitlement_id))])
        (cond
          [(or (not revision)
               (not (= (entitlement-revision-revision revision)
                       (hash-ref snapshot 'revision))))
           (hasheq 'status "stale-revision")]
          [else
           (let ([record
                  (storage-issued-credential-ref
                   storage (entitlement-revision-issuance-outbox-id revision))])
             (if (not record)
                 (hasheq 'status "proof-unavailable")
                 (with-handlers
                     ([exn:fail?
                       (lambda (_) (hasheq 'status "invalid-proof"))])
                   (let* ([envelope
                           (read-envelope
                            (open-input-bytes
                             (issued-credential-record-envelope-bytes
                              record)))]
                          [credential
                           (verify-credential envelope trust-store)])
                     (cond
                       [(or (not (same-identity-and-bytes?
                                  credential record revision
                                  issuer subject-type subject-id))
                            (not (product-in-signed-grants?
                                  credential product-id)))
                        (hasheq 'status "invalid-proof")]
                       [else
                        (let* ([policy (credential-status credential #:at at)]
                               [latest
                                (storage-latest-entitlement-revision
                                 storage (hash-ref snapshot
                                                   'entitlement_id))])
                          ;; The ledger can advance between reads; never
                          ;; claim this was current if a new revision appeared.
                          (cond
                            [(or (not latest)
                                 (not (= (entitlement-revision-revision latest)
                                         (hash-ref snapshot 'revision))))
                             (hasheq 'status "stale-revision")]
                            [(not (hash-ref policy 'usable?))
                             (hasheq 'status "not-usable"
                                     'reasons
                                     (map symbol->string
                                          (hash-ref policy 'reasons)))]
                            [else
                             (hasheq
                              'status "verified-proof"
                              'entitlement_id
                              (entitlement-revision-entitlement-id revision)
                              'revision (entitlement-revision-revision revision)
                              'credential (envelope->jsexpr envelope))]))]))))))]))))
