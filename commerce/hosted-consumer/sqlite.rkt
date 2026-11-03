#lang racket/base

;; Product-server-side, durable anti-rollback fence for current hosted Permit
;; proof. This is NOT a credential cache or an authorization decision.
;; Only a freshly fetched, independently signature-verified Commerce proof
;; may advance the high-water revision; a signed withdrawal is remembered too.
(provide initialize-sqlite-hosted-watermark-store!
         read-hosted-entitlement-watermark
         remember-hosted-entitlement-proof!)

(require db
         permit/credential
         permit/envelope
         permit/trust
         "../private/model.rkt")

(define (refuse code)
  (raise
   (exn:fail:commerce "Hosted entitlement watermark refused"
                      (current-continuation-marks) code (hash))))

(define (valid-identity? value)
  (and (string? value)
       (<= 1 (string-length value) 256)
       (not (regexp-match? #px"[\r\n]" value))))

(define (check-scope service issuer kind subject offer product)
  (unless (andmap valid-identity?
                  (list service issuer kind subject offer product))
    (refuse 'hosted-watermark-invalid-scope)))

(define (with-db path proc #:mode [mode 'read/write])
  (define db
    (sqlite3-connect #:database path #:mode mode
                     #:busy-retry-delay 0.05 #:busy-retry-limit 40))
  (dynamic-wind void (lambda () (proc db))
                (lambda () (disconnect db))))

(define (initialize-sqlite-hosted-watermark-store! path)
  (unless (path-string? path)
    (raise-argument-error 'initialize-sqlite-hosted-watermark-store!
                          "path-string?" path))
  (with-db
   path
   (lambda (db)
     (query-exec
      db
      "CREATE TABLE IF NOT EXISTS hosted_entitlement_watermark (
         service_id TEXT NOT NULL,
         issuer TEXT NOT NULL,
         subject_type TEXT NOT NULL,
         subject_id TEXT NOT NULL,
         offer_id TEXT NOT NULL,
         product_id TEXT NOT NULL,
         entitlement_id TEXT NOT NULL,
         revision INTEGER NOT NULL CHECK(revision >= 0),
         observed_at INTEGER NOT NULL CHECK(observed_at >= 0),
         PRIMARY KEY(service_id,issuer,subject_type,subject_id,offer_id,product_id)
       )")
     (query-exec
      db
      "CREATE TRIGGER IF NOT EXISTS hosted_watermark_no_delete
       BEFORE DELETE ON hosted_entitlement_watermark
       BEGIN SELECT RAISE(ABORT, 'watermark deletion prohibited'); END"))
   #:mode 'create)
  (void))

(define (scope-row db service issuer kind subject offer product)
  (query-maybe-row
   db
   "SELECT entitlement_id, revision FROM hosted_entitlement_watermark
    WHERE service_id=? AND issuer=? AND subject_type=? AND subject_id=?
      AND offer_id=? AND product_id=?"
   service issuer kind subject offer product))

(define (read-hosted-entitlement-watermark path
                                          #:service-id service
                                          #:issuer issuer
                                          #:subject-type kind
                                          #:subject-id subject
                                          #:offer-id offer
                                          #:product-id product)
  (unless (path-string? path)
    (raise-argument-error 'read-hosted-entitlement-watermark "path-string?" path))
  (check-scope service issuer kind subject offer product)
  (with-db
   path
   (lambda (db)
     (define row (scope-row db service issuer kind subject offer product))
     (and row
          (hasheq 'entitlement_id (vector-ref row 0)
                  'revision (vector-ref row 1))))))

(define (signed-scope-includes? credential product)
  (for/or ([grant
            (in-list
             (hash-ref (verified-credential-claims credential) 'grants))])
    (and (member product
                 (hash-ref (hash-ref grant 'scope) 'products))
         #t)))

(define (remember-hosted-entitlement-proof!
         path proof trust-store
         #:service-id service
         #:issuer issuer
         #:subject-type kind
         #:subject-id subject
         #:offer-id offer
         #:product-id product
         #:observed-at observed-at)
  (unless (and (path-string? path)
               (trust-store? trust-store)
               (exact-nonnegative-integer? observed-at))
    (refuse 'hosted-watermark-invalid-request))
  (check-scope service issuer kind subject offer product)
  (unless (and (hash? proof)
               (member (hash-ref proof 'status #f)
                       '("verified-proof" "recorded-withdrawal"))
               (valid-identity? (hash-ref proof 'entitlement_id #f))
               (exact-nonnegative-integer? (hash-ref proof 'revision #f))
               (hash? (hash-ref proof 'credential #f)))
    (refuse 'hosted-watermark-invalid-proof))
  ;; Do not trust the response's status, revision, or envelope spelling as
  ;; payment authority. Parse and verify the actual Permit signature here.
  (define verified
    (with-handlers ([exn:fail? (lambda (_) (refuse 'hosted-watermark-invalid-proof))])
      (verify-credential
       (jsexpr->envelope (hash-ref proof 'credential))
       trust-store)))
  (unless (and (equal? (verified-credential-type verified) "entitlement")
               (equal? (verified-credential-issuer verified) issuer)
               (equal? (verified-credential-subject-type verified) kind)
               (equal? (verified-credential-subject-id verified) subject)
               (signed-scope-includes? verified product))
    (refuse 'hosted-watermark-scope-mismatch))
  (unless (and (equal? (verified-credential-entitlement-id verified)
                       (hash-ref proof 'entitlement_id))
               (= (verified-credential-revision verified)
                  (hash-ref proof 'revision)))
    (refuse 'hosted-watermark-invalid-proof))
  ;; The verified signature and declared scope are necessary but still not
  ;; sufficient for paid admission. The backend must fetch CURRENT state per
  ;; action, check usable features/quota and fail closed on outage.
  (define entitlement (hash-ref proof 'entitlement_id))
  (define revision (hash-ref proof 'revision))
  (with-db
   path
   (lambda (db)
     (call-with-transaction
      db
      (lambda ()
        (define existing
          (scope-row db service issuer kind subject offer product))
        (cond
          [(not existing)
           (query-exec
            db
            "INSERT INTO hosted_entitlement_watermark
             (service_id, issuer, subject_type, subject_id, offer_id,
              product_id, entitlement_id, revision, observed_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
            service issuer kind subject offer product
            entitlement revision observed-at)
           'advanced]
          [(not (equal? (vector-ref existing 0) entitlement))
           (refuse 'hosted-watermark-lineage-mismatch)]
          [(< revision (vector-ref existing 1))
           (refuse 'hosted-watermark-stale-revision)]
          [(= revision (vector-ref existing 1)) 'replayed]
          [else
           (query-exec
            db
            "UPDATE hosted_entitlement_watermark
             SET revision=?, observed_at=?
             WHERE service_id=? AND issuer=? AND subject_type=? AND subject_id=?
               AND offer_id=? AND product_id=?"
            revision observed-at service issuer kind subject offer product)
           'advanced]))
      #:option 'immediate))))
