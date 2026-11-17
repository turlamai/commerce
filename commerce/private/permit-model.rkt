#lang racket/base

(provide
 (struct-out permit-grant-policy)
 (struct-out permit-constraints-policy)
 (struct-out permit-entitlement-policy)
 (struct-out permit-policy-catalog)
 (struct-out permit-snapshot-request))

;; These values are private constructors. commerce/permit exposes smart
;; constructors so every policy has crossed Permit's schema validation.
(struct permit-grant-policy
  (products product-families edition feature-policy features addons
            capabilities)
  #:transparent)

(struct permit-constraints-policy
  (use-expires-at updates-through features-through version-min version-max
                  named-seats device-activations concurrent-seats
                  installation-id activation-required?
                  ;; Commerce-side policy meaning, never a Permit payload
                  ;; field: when set, issuance derives the concrete
                  ;; updates_through from the order's paid evidence.
                  updates-through-duration-days
                  ;; Initial hosted use window from authenticated paid-at,
                  ;; expressed as UTC calendar months rather than fixed days.
                  use-duration-months)
  #:transparent)

(struct permit-entitlement-policy
  (id version subject-type grants constraints withdrawal-mode)
  #:transparent)

(struct permit-policy-catalog
  (offers-by-id policies-by-id deleted-offer-ids)
  #:transparent)

;; payload-bytes is the only serialization that the later signer may consume.
(struct permit-snapshot-request
  (policy-id policy-version action source-idempotency-key payload payload-bytes)
  #:transparent)
