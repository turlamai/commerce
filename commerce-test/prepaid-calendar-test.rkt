#lang racket/base

(require commerce commerce/permit commerce/issuer commerce/provider
         commerce/journal commerce/storage commerce/storage/sqlite
         permit/issuer permit/envelope
         rackunit racket/file json file/sha1)

(define (make-catalog months)
  (make-permit-policy-catalog
   (list (offer "hosted-monthly" "hosted" 'one-time
                (money "CNY" 2900) "hosted-monthly-v1"))
   (list (make-permit-entitlement-policy
          "hosted-monthly-v1" 1 #:subject-type 'account
          #:grants (list (make-permit-grant-policy #:products '("hosted")))
          #:constraints (make-permit-constraints-policy
                         #:use-duration-months months)))))

(define grant-intent
  (rights-intent "mock/order/grant" 'grant "mock" "order"
                 "hosted-monthly" "account-test" 1792108800))

(define (snapshot paid-at #:months [months 1]
                  #:issued-at [issued-at "2028-03-01T00:00:00Z"])
  (prepare-permit-snapshot
   (make-catalog months) grant-intent
   #:issuer "com.example.commerce" #:credential-id "cred-test"
   #:entitlement-id "ent-test" #:issued-at issued-at #:paid-at paid-at))

(define (expiry request)
  ;; Inspect emitted payload bytes, not just the in-memory policy field.
  (hash-ref (hash-ref (bytes->jsexpr
                      (permit-snapshot-request-payload-bytes request))
                     'constraints) 'use_expires_at))

(test-case "calendar-month windows use UTC paid evidence, clamp and preserve time"
  (for ([case (in-list
               '((1769853637 1 "2026-02-28T10:00:37Z")
                 (1801389637 1 "2027-02-28T10:00:37Z")
                 (1832925637 1 "2028-02-29T10:00:37Z")
                 (1709200837 12 "2025-02-28T10:00:37Z")
                 (1798711237 1 "2027-01-31T10:00:37Z")
                 (949363199 1 "2000-02-29T23:59:59Z")
                 (4105123199 1 "2100-02-28T23:59:59Z")
                 (1777543237 1 "2026-05-30T10:00:37Z")
                 (1769853637 2 "2026-03-31T10:00:37Z")))])
    (check-equal? (expiry (snapshot (car case) #:months (cadr case)))
                  (caddr case))))

(test-case "late issuance and replay do not restart the paid month"
  (define first (snapshot 1769853637 #:issued-at "2026-02-01T00:00:00Z"))
  (define late (snapshot 1769853637 #:issued-at "2026-04-01T00:00:00Z"))
  (check-equal? (expiry first) (expiry late))
  (check-equal? first (snapshot 1769853637 #:issued-at "2026-02-01T00:00:00Z")))

(test-case "missing payment evidence and conflicting policy refuse"
  (check-exn (lambda (e) (and (exn:fail:commerce? e)
                             (eq? (exn:fail:commerce-code e)
                                  'order-paid-evidence-required)))
             (lambda () (snapshot #f)))
  (for ([bad (in-list '(0 -1 1.5 "1"))])
    (check-exn exn:fail:contract?
               (lambda () (make-permit-constraints-policy #:use-duration-months bad))))
  (check-exn exn:fail:contract?
             (lambda () (make-permit-constraints-policy
                         #:use-duration-months 1
                         #:use-expires-at "2026-02-28T00:00:00Z")))
  (check-exn exn:fail:commerce? (lambda () (snapshot 253402300799))))

(test-case "initial grant cannot bypass lineage rejection with a duration"
  (define previous (permit-snapshot-request-payload (snapshot 1769853637)))
  (check-exn exn:fail:commerce?
             (lambda ()
               (prepare-permit-snapshot
                (make-catalog 1) grant-intent
                #:issuer "com.example.commerce" #:credential-id "cred-next"
                #:entitlement-id "ent-test" #:issued-at "2026-03-01T00:00:00Z"
                #:paid-at 1772272837 #:previous previous))))

(test-case "worker persists a signed paid-month window across restart and replay"
  (define directory (make-temporary-file "commerce-prepaid-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define path (build-path directory "commerce.sqlite"))
      (define storage (open-sqlite-commerce-storage path))
      (define raw #"synthetic authenticated payment")
      (define event
        (make-verified-payment-event
         "mock" "calendar-paid" (bytes->hex-string (sha256-bytes raw))
         'payment-succeeded "calendar-order" "hosted-monthly" "account-test"
         (money "CNY" 2900) 1769853637))
      (journal-accept! storage raw event #:received-at 1769904000)
      (storage-project-next! storage #:processed-at 1769904001)
      (define-values (private-key public-key) (generate-ed25519-keypair))
      (define trust
        (jsexpr->trust-store
         (hasheq 'protocol "permit-trust-store" 'version 1
                 'issuer "com.example.commerce"
                 'keys (hasheq 'calendar-test
                               (hasheq 'algorithm "Ed25519"
                                       'public_key (public-key->base64 public-key)
                                       'status "active" 'purposes '("entitlement")
                                       'not_before 'null 'not_after 'null)))))
      (define worker
        (make-issuance-worker
         #:catalog (make-catalog 1) #:issuer "com.example.commerce"
         #:private-key private-key #:key-id "calendar-test" #:trust-store trust
         ;; Fulfillment occurs two months after payment, deliberately.
         #:clock (lambda () (values 1775001600 "2026-04-01T00:00:00Z"))))
      (define result (process-issuance-work! worker storage))
      (check-eq? (issuance-result-disposition result) 'completed)
      (define revision
        (issuance-completion-revision (issuance-result-completion result)))
      (define payload (entitlement-revision-payload-bytes revision))
      (check-equal? (hash-ref (hash-ref (bytes->jsexpr payload) 'constraints)
                              'use_expires_at) "2026-02-28T10:00:37Z")
      (check-equal? (hash-ref (hash-ref (bytes->jsexpr payload) 'subject) 'type)
                    "account")
      (define signed (issue-credential payload private-key "calendar-test" trust))
      (check-equal? (permit-envelope-payload signed) payload)
      (define entitlement-id (issuance-result-entitlement-id result))
      (storage-close storage)
      (set! storage (open-sqlite-commerce-storage path))
      (check-equal?
       (entitlement-revision-payload-bytes
        (storage-latest-entitlement-revision storage entitlement-id)) payload)
      (check-eq? (journal-acceptance-disposition
                  (journal-accept! storage raw event #:received-at 1775001601))
                 'replayed)
      (check-false (storage-project-next! storage #:processed-at 1775001602))
      (check-false (process-issuance-work! worker storage))
      (storage-close storage))
    (lambda () (delete-directory/files directory))))

(test-case "withdrawal does not restart a calendar grant and policies compose"
  (define previous (permit-snapshot-request-payload (snapshot 1769853637)))
  (define withdraw-intent
    (rights-intent "mock/order/withdraw" 'withdraw "mock" "order"
                   "hosted-monthly" "account-test" 1769904000))
  (define withdrawal
    (prepare-permit-snapshot
     (make-catalog 1) withdraw-intent
     #:issuer "com.example.commerce" #:credential-id "cred-withdraw"
     #:entitlement-id "ent-test" #:issued-at "2026-02-01T00:00:00Z"
     #:previous previous))
  (check-equal? (expiry withdrawal) "2026-02-01T00:00:00Z")
  (define composed
    (make-permit-policy-catalog
     (list (offer "hosted-monthly" "hosted" 'one-time
                  (money "CNY" 2900) "hosted-monthly-v1"))
     (list (make-permit-entitlement-policy
            "hosted-monthly-v1" 1 #:subject-type 'account
            #:grants (list (make-permit-grant-policy #:products '("hosted")))
            #:constraints (make-permit-constraints-policy
                           #:use-duration-months 1
                           #:updates-through-duration-days 365)))))
  (define request
    (prepare-permit-snapshot
     composed grant-intent #:issuer "com.example.commerce"
     #:credential-id "cred-composed" #:entitlement-id "ent-test"
     #:issued-at "2026-02-01T00:00:00Z" #:paid-at 1769853637))
  (check-equal? (expiry request) "2026-02-28T10:00:37Z")
  (check-equal? (hash-ref (hash-ref (bytes->jsexpr
                                    (permit-snapshot-request-payload-bytes request))
                                   'constraints) 'updates_through)
                "2027-01-31T10:00:37Z"))
