#lang racket/base

(require rackunit
         commerce
         commerce/issuer
         commerce/journal
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         commerce/hosted-admission
         permit/issuer
         file/sha1
         racket/file)

(define issuer-name "com.turinglambdaai")
(define price (money "USD" 2900))
(define-values (private-key public-key) (generate-ed25519-keypair))
(define trust
  (jsexpr->trust-store
   (hasheq 'protocol "permit-trust-store" 'version 1
           'issuer issuer-name
           'keys (hasheq 'test-2026
                         (hasheq 'algorithm "Ed25519"
                                 'public_key (public-key->base64 public-key)
                                 'status "active"
                                 'purposes '("entitlement")
                                 'not_before 'null
                                 'not_after 'null)))))
(define catalog
  (make-permit-policy-catalog
   (list (offer "publy-pro-lifetime" "publy" 'one-time price "publy-pro-v1"))
   (list (make-permit-entitlement-policy
          "publy-pro-v1" 1
          #:subject-type 'account
          #:grants (list (make-permit-grant-policy
                          #:products '("publy")
                          #:edition "pro"
                          #:feature-policy 'explicit
                          #:features '("export")
                          #:addons '("extra-themes")))
          #:constraints
          (make-permit-constraints-policy
           #:updates-through "2026-10-19T00:00:00Z"
           #:use-expires-at "2026-10-20T00:00:00Z")))))
(define (worker now time)
  (make-issuance-worker
   #:catalog catalog #:issuer issuer-name #:private-key private-key
   #:key-id "test-2026" #:trust-store trust
   #:clock (lambda () (values now time))))
(define (event raw event-id kind occurred-at)
  (make-verified-payment-event
   "mock" event-id (bytes->hex-string (sha256-bytes raw))
   kind "order-001" "publy-pro-lifetime" "account-001" price occurred-at))

(test-case "hosted admission evaluates exact Permit feature, edition and addon"
  (define dir (make-temporary-file "commerce-hosted-admission-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage
       (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
     (dynamic-wind
      void
      (lambda ()
        (define paid #"verified-paid")
        (define refunded #"verified-refunded")
        (define (admit kind right
                       #:product [product "publy"]
                       #:subject [subject "account-001"]
                       #:at [at "2026-10-18T00:00:00Z"]
                       #:published-at [published-at #f]
                       #:minimum [minimum #f]
                       #:lineage [lineage #f]
                       #:authorize [authorize
                                    (lambda (_i _t s _o product-id)
                                      (and (equal? s "account-001")
                                           (equal? product-id "publy")))])
          (current-hosted-right-admission
           storage #:issuer issuer-name #:subject-type "account"
           #:subject-id subject #:offer-id "publy-pro-lifetime"
           #:product-id product #:right-kind kind #:right-id right
           #:authorize authorize #:trust-store trust
           #:at at #:published-at published-at
           #:minimum-revision minimum
           #:expected-entitlement-id lineage))
        (journal-accept! storage paid
                         (event paid "paid-001" 'payment-succeeded 98)
                         #:received-at 99)
        (storage-project-next! storage #:processed-at 99)
        (check-eq? (issuance-result-disposition
                    (process-issuance-work!
                     (worker 100 "2026-10-17T03:00:00Z") storage))
                   'completed)
        (let* ([granted (admit 'feature "export")]
               [entitlement-id (hash-ref granted 'entitlement_id)])
          (check-true (hash-ref granted 'allowed))
          (check-equal? (hash-ref granted 'status) "entitled")
          (check-equal? (hash-ref granted 'revision) 0)
          (check-false (hash-ref (admit 'feature "unlisted") 'allowed))
          (check-true (hash-ref (admit 'edition "pro") 'allowed))
          (check-false (hash-ref (admit 'edition "enterprise") 'allowed))
          (check-true (hash-ref (admit 'addon "extra-themes") 'allowed))
          (check-false (hash-ref (admit 'addon "missing") 'allowed))
          (check-false (hash-ref (admit 'update "software") 'allowed))
          (check-true (hash-ref (admit 'update "software"
                                       #:published-at "2026-10-18T00:00:00Z")
                                'allowed))
          (check-false
           (hash-ref (admit 'update "software"
                            #:published-at "2026-10-21T00:00:00Z")
                     'allowed))
          (check-false (hash-ref (admit 'feature "export"
                                        #:at "2026-10-21T00:00:00Z")
                                 'allowed))
          (check-equal? (hash-ref (admit 'feature "export" #:minimum 1)
                                  'status)
                        "stale-revision")
          (check-equal? (hash-ref (admit 'feature "export"
                                        #:lineage "entitlement-not-ours")
                                  'status)
                        "lineage-mismatch")
          (check-equal? (hash-ref (admit 'feature "export"
                                        #:lineage entitlement-id)
                                  'status)
                        "entitled")
          (check-exn exn:fail?
                     (lambda () (admit 'feature "export" #:product "movebit")))
          (check-exn exn:fail?
                     (lambda () (admit 'feature "export" #:subject "other")))
          (journal-accept! storage refunded
                           (event refunded "refund-001" 'payment-refunded 110)
                           #:received-at 111)
          (check-equal? (hash-ref (admit 'feature "export") 'status)
                        "refund-pending")
          (storage-project-next! storage #:processed-at 112)
          (check-equal? (hash-ref (admit 'feature "export") 'status)
                        "refund-pending")
          (check-eq? (issuance-result-disposition
                      (process-issuance-work!
                       (worker 130 "2026-10-18T03:00:00Z") storage))
                     'completed)
          (check-false (hash-ref (admit 'feature "export") 'allowed))
          (check-equal? (hash-ref (admit 'feature "export") 'status)
                        "recorded-withdrawal")))
      (lambda () (storage-close storage))))
   (lambda () (delete-directory/files dir))))
