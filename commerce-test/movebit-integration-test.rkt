#lang racket/base

;; MoveBit is a consumer fixture, not a built-in Commerce product.
;; This test uses a synthetic price/offer and issues NO real checkout.
;; It proves the existing generic Commerce -> Permit snapshot contract can
;; represent a candidate Free + Pro desktop product without payment logic
;; or a hard-coded MoveBit branch in the service.

(require commerce
         commerce/permit
         permit/issuer
         rackunit)

(define fixture-offer-id "movebit-pro-test-only")
(define fixture-policy-id "movebit-pro-test-only-v1")

;; USD 12.34 is a test sentinel, NOT the product's price or sales plan.
(define fixture-offer
  (offer fixture-offer-id "movebit" 'one-time
         (money "USD" 1234) fixture-policy-id))

(define fixture-policy
  (make-permit-entitlement-policy
   fixture-policy-id 1
   #:subject-type 'person
   #:grants
   (list (make-permit-grant-policy
          #:products '("movebit")
          #:edition "pro"
          ;; Candidate identifiers reserved in MoveBit's domain, not claims
          ;; that these features have shipped or should be charged for.
          #:features '("advanced-work-insights"
                       "advanced-character-customization")))))

(define catalog (make-permit-policy-catalog
                 (list fixture-offer)
                 (list fixture-policy)))

(define (intent action)
  (rights-intent
   (format "fixture/movebit-order/~a" action)
   action "mock" "fixture-movebit-order"
   fixture-offer-id "fixture-subject" 1792108800))

(define (grant-request)
  (prepare-permit-snapshot
   catalog (intent 'grant)
   #:issuer "movebit-ci-fixture"
   #:credential-id "fixture-movebit-credential-r0"
   #:entitlement-id "fixture-movebit-entitlement"
   #:issued-at "2026-10-21T00:00:00Z"))

(test-case "MoveBit candidate Offer maps to signed-rights input without a real payment"
  (define request (grant-request))
  (check-eq? (permit-snapshot-request-action request) 'grant)
  (check-equal? (permit-snapshot-request-policy-id request) fixture-policy-id)
  (check-equal? (permit-snapshot-request-policy-version request) 1)
  (check-equal? (permit-snapshot-request-source-idempotency-key request)
                "fixture/movebit-order/grant")
  (define payload (permit-snapshot-request-payload request))
  (check-equal? (permit-snapshot-request-payload-bytes request)
                (payload->bytes payload))
  (check-equal? (hash-ref payload 'issuer) "movebit-ci-fixture")
  (check-equal? (hash-ref payload 'entitlement_id)
                "fixture-movebit-entitlement")
  (check-equal? (hash-ref (hash-ref payload 'subject) 'id)
                "fixture-subject")
  (define grant (car (hash-ref payload 'grants)))
  (check-equal? (hash-ref (hash-ref grant 'scope) 'products)
                '("movebit"))
  (check-equal? (hash-ref grant 'edition) "pro")
  (check-equal? (hash-ref grant 'features)
                '("advanced-work-insights"
                  "advanced-character-customization"))
  ;; Exactly identical recorded inputs produce identical bytes on replay.
  (check-equal? request (grant-request)))

(test-case "MoveBit mock refund prepares a successor rather than altering history"
  (define initial (permit-snapshot-request-payload (grant-request)))
  (define successor
    (prepare-permit-snapshot
     catalog (intent 'withdraw)
     #:issuer "movebit-ci-fixture"
     #:credential-id "fixture-movebit-credential-r1"
     #:entitlement-id "fixture-movebit-entitlement"
     #:issued-at "2026-10-22T00:00:00Z"
     #:previous initial))
  (define payload (permit-snapshot-request-payload successor))
  (check-eq? (permit-snapshot-request-action successor) 'withdraw)
  (check-equal? (hash-ref payload 'revision) 1)
  (check-equal? (hash-ref payload 'entitlement_id)
                (hash-ref initial 'entitlement_id))
  (check-equal? (hash-ref payload 'subject)
                (hash-ref initial 'subject))
  (check-equal? (hash-ref (hash-ref payload 'constraints)
                          'use_expires_at)
                "2026-10-22T00:00:00Z")
  (check-equal? (permit-snapshot-request-payload-bytes successor)
                (payload->bytes payload)))

(test-case "Offer identity cannot silently grant another product"
  (define bad-policy
    (make-permit-entitlement-policy
     fixture-policy-id 1
     #:subject-type 'person
     #:grants (list (make-permit-grant-policy
                     #:products '("different-product")
                     #:edition "pro"))))
  (check-exn
   exn:fail:commerce?
   (lambda ()
     (make-permit-policy-catalog (list fixture-offer)
                                 (list bad-policy)))))
