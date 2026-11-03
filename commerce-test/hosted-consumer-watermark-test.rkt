#lang racket/base

(require rackunit
         racket/file
         commerce
         commerce/permit
         commerce/hosted-consumer/sqlite
         permit/issuer
         permit/envelope)

;; All fixtures are locally generated. No merchant, account, or signing
;; material is committed; no network or live entitlement is involved.
(define issuer "fixture-hosted-issuer")
(define-values (private-key public-key) (generate-ed25519-keypair))
(define trust
  (jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store"
           'version 1 'issuer issuer
           'keys
           (hasheq 'fixture-key
                   (hasheq 'algorithm "Ed25519"
                           'public_key (public-key->base64 public-key)
                           'status "active"
                           'purposes '("entitlement")
                           'not_before 'null 'not_after 'null)))))

(define catalog
  (make-permit-policy-catalog
   (list (offer "movebit-pro-test-only" "movebit" 'one-time
                (money "USD" 1234) "movebit-policy-v1"))
   (list (make-permit-entitlement-policy
          "movebit-policy-v1" 1
          #:subject-type 'person
          #:grants
          (list (make-permit-grant-policy
                 #:products '("movebit")
                 #:edition "pro"))))))

(define (intent action)
  (rights-intent
   (format "fixture/movebit/~a" action)
   action "mock" "fixture-order"
   "movebit-pro-test-only" "subject-a" 1793692800))

(define (signed-snapshot action
                         #:entitlement [entitlement "fixture-entitlement"])
  (define grant
    (prepare-permit-snapshot
     catalog (intent 'grant)
     #:issuer issuer
     #:credential-id "fixture-cred-0"
     #:entitlement-id entitlement
     #:issued-at "2026-11-03T00:00:00Z"))
  (define request
    (if (eq? action 'grant)
        grant
        (prepare-permit-snapshot
         catalog (intent 'withdraw)
         #:issuer issuer
         #:credential-id "fixture-cred-1"
         #:entitlement-id entitlement
         #:issued-at "2026-11-04T00:00:00Z"
         #:previous (permit-snapshot-request-payload grant))))
  (define payload (permit-snapshot-request-payload request))
  (hasheq
   'status (if (eq? action 'grant) "verified-proof" "recorded-withdrawal")
   'entitlement_id entitlement
   'revision (hash-ref payload 'revision)
   'credential
   (envelope->jsexpr
    (issue-credential (permit-snapshot-request-payload-bytes request)
                      private-key "fixture-key" trust))))

(define grant (signed-snapshot 'grant))
(define withdrawal (signed-snapshot 'withdraw))

(define (with-store proc)
  (define dir (make-temporary-file "commerce-hosted-watermark-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define path (build-path dir "marks.sqlite"))
     (initialize-sqlite-hosted-watermark-store! path)
     (proc path))
   (lambda () (delete-directory/files dir))))

(define (record path proof
                #:subject [subject "subject-a"]
                #:product [product "movebit"]
                #:offer [offer "movebit-pro-test-only"]
                #:service [service "movebit-service"])
  (remember-hosted-entitlement-proof!
   path proof trust
   #:service-id service
   #:issuer issuer #:subject-type "person" #:subject-id subject
   #:offer-id offer #:product-id product
   #:observed-at 1793692800))

(define (read-mark path)
  (read-hosted-entitlement-watermark
   path #:service-id "movebit-service"
   #:issuer issuer #:subject-type "person" #:subject-id "subject-a"
   #:offer-id "movebit-pro-test-only" #:product-id "movebit"))

(define (deny? code thunk)
  (check-exn
   (lambda (e)
     (and (exn:fail:commerce? e)
          (eq? (exn:fail:commerce-code e) code)))
   thunk))

(test-case "signed refund advances high-water and refuses old paid grant replay"
  (with-store
   (lambda (path)
     (check-false (read-mark path))
     (check-eq? (record path grant) 'advanced)
     (check-eq? (record path grant) 'replayed)
     (check-equal? (hash-ref (read-mark path) 'revision) 0)
     (check-eq? (record path withdrawal) 'advanced)
     (check-equal? (hash-ref (read-mark path) 'revision) 1)
     (deny? 'hosted-watermark-stale-revision
            (lambda () (record path grant)))
     (check-eq? (record path withdrawal) 'replayed))))

(test-case "signed proof scope and lineage cannot be swapped"
  (with-store
   (lambda (path)
     (deny? 'hosted-watermark-scope-mismatch
            (lambda () (record path grant #:subject "other-subject")))
     (deny? 'hosted-watermark-scope-mismatch
            (lambda () (record path grant #:product "taskly")))
     (deny? 'hosted-watermark-invalid-proof
            (lambda () (record path (hash-set grant 'revision 12))))
     (deny? 'hosted-watermark-invalid-proof
            (lambda () (record path (hash-set grant 'status "paid"))))
     (check-eq? (record path grant) 'advanced)
     (define other-lineage
       (signed-snapshot 'grant #:entitlement "different-entitlement"))
     (deny? 'hosted-watermark-lineage-mismatch
            (lambda () (record path other-lineage))))))

(test-case "watermark database loss fails closed rather than resets a revision"
  (with-store
   (lambda (path)
     (record path withdrawal)
     (delete-file path)
     (check-exn exn:fail? (lambda () (record path grant)))
     (check-exn exn:fail? (lambda () (read-mark path))))))
