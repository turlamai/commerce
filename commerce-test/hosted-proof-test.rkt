#lang racket/base

(require rackunit
         commerce
         commerce/issuer
         commerce/journal
         commerce/permit
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         commerce/hosted-proof
         permit/issuer
         racket/file
         file/sha1)

(define usd-29 (money "USD" 2900))
(define issuer-name "com.turinglambdaai")
(define-values (private-key public-key) (generate-ed25519-keypair))
(define-values (_wrong-private wrong-public) (generate-ed25519-keypair))

(define (make-trust public [status "active"])
  (jsexpr->trust-store
   (hasheq
    'protocol "permit-trust-store"
    'version 1
    'issuer issuer-name
    'keys (hasheq 'test-2026
                  (hasheq 'algorithm "Ed25519"
                          'public_key (public-key->base64 public)
                          'status status
                          'purposes '("entitlement")
                          'not_before 'null
                          'not_after 'null)))))

(define trust (make-trust public-key))
(define catalog
  (make-permit-policy-catalog
   (list (offer "taskly-pro-lifetime" "taskly" 'one-time
                usd-29 "taskly-pro-v1"))
   (list (make-permit-entitlement-policy
          "taskly-pro-v1" 1
          #:subject-type 'account
          #:grants (list (make-permit-grant-policy
                          #:products '("taskly")
                          #:edition "pro"))
          #:constraints (make-permit-constraints-policy
                         #:use-expires-at "2026-10-19T00:00:00Z")))))

(define (worker [now 100] [issued-at "2026-10-17T03:00:00Z"])
  (make-issuance-worker
   #:catalog catalog #:issuer issuer-name
   #:private-key private-key #:key-id "test-2026"
   #:trust-store trust
   #:clock (lambda () (values now issued-at))))

(define (event raw id kind at)
  (make-verified-payment-event
   "mock" id (bytes->hex-string (sha256-bytes raw))
   kind "order-001" "taskly-pro-lifetime" "customer-001" usd-29 at))

(test-case "signed Permit evidence enforces subject, product, trust, time and refund"
  (define dir (make-temporary-file "commerce-hosted-proof-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage
       (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
     (dynamic-wind
      void
      (lambda ()
        (define paid #"authenticated-payment")
        (define refunded #"authenticated-refund")
        (define (proof #:subject [subject "customer-001"]
                       #:product [product "taskly"]
                       #:store [store trust]
                       #:authorize [authorize
                                    (lambda (_issuer _type _id _offer _product) #t)]
                       #:minimum [minimum #f]
                       #:lineage [lineage #f]
                       #:at [at "2026-10-18T00:00:00Z"])
          (current-verified-entitlement-proof
           storage #:issuer issuer-name #:subject-type "account"
           #:subject-id subject #:offer-id "taskly-pro-lifetime"
           #:product-id product #:authorize authorize
           #:trust-store store #:at at
           #:minimum-revision minimum
           #:expected-entitlement-id lineage))
        (journal-accept! storage paid
                         (event paid "paid-001" 'payment-succeeded 98)
                         #:received-at 99)
        (storage-project-next! storage #:processed-at 99)
        (check-eq? (issuance-result-disposition
                    (process-issuance-work! (worker) storage))
                   'completed)
        (let* ([valid (proof)]
               [entitlement-id (hash-ref valid 'entitlement_id)])
          (check-equal? (hash-ref valid 'status) "verified-proof")
          (check-equal? (hash-ref valid 'revision) 0)
          (check-true (hash? (hash-ref valid 'credential)))
          (check-equal? (hash-ref (proof #:lineage entitlement-id) 'status)
                        "verified-proof")
          (check-equal? (proof #:minimum 1 #:lineage entitlement-id)
                        (hasheq 'status "stale-revision"))
          (check-equal? (hash-ref (proof #:product "movebit") 'status)
                        "invalid-proof")
          (check-exn exn:fail?
                     (lambda ()
                       (proof #:product "movebit" #:authorize
                              (lambda (_issuer _type _id _offer product)
                                (equal? product "taskly")))))
          (check-equal?
           (hash-ref (proof #:store (make-trust wrong-public)) 'status)
           "invalid-proof")
          (check-equal?
           (hash-ref (proof #:store (make-trust public-key "revoked")) 'status)
           "invalid-proof")
          (check-equal?
           (hash-ref (proof #:at "2026-10-20T00:00:00Z") 'status)
           "not-usable")
          (check-exn exn:fail?
                     (lambda ()
                       (proof #:subject "other-account"
                              #:authorize
                              (lambda (_issuer _type id _offer product)
                                (and (equal? id "customer-001")
                                     (equal? product "taskly"))))))
          (journal-accept! storage refunded
                           (event refunded "refund-001" 'payment-refunded 110)
                           #:received-at 111)
          (storage-project-next! storage #:processed-at 112)
          (check-eq?
           (issuance-result-disposition
            (process-issuance-work!
             (worker 130 "2026-10-18T03:00:00Z") storage))
           'completed)
          (check-equal?
           (hash-ref (proof #:minimum 1 #:lineage entitlement-id) 'status)
           "recorded-withdrawal")))
      (lambda () (storage-close storage))))
   (lambda () (delete-directory/files dir))))
