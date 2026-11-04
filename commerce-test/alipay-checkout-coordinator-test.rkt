#lang racket/base

(require rackunit json racket/file db
         crypto crypto/libcrypto base64
         commerce commerce/alipay commerce/admission
         commerce/alipay/checkout-coordinator
         commerce/alipay/checkout-idempotency
         commerce/storage commerce/storage/sqlite)

(define fixture-offer (offer "publy-personal-monthly" "publy" 'one-time (money "CNY" 2900) "fixture-policy"))
(define fixture-key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
(define fixture-admission
  (hasheq 'version 1 'provider "alipay" 'environment "sandbox"
          'merchant_app_id "fixture-app" 'seller_id "fixture-seller"
          'product_category "fixture" 'admission_reference "fixture"
          'cost_reference "fixture" 'checkout_api "alipay.trade.page.pay"
          'read_api "alipay.trade.query" 'approved_at 100 'expires_at 1000
          'capabilities
          (list (hasheq 'offer_id "publy-personal-monthly" 'product_id "publy"
                        'method "alipay" 'transaction_type "one-time" 'currency "CNY"
                        'amount_minor 2900 'min_minor 1 'max_minor 100000))))

(test-case "trusted checkout is durable, idempotent and rejects identity or offer substitution"
  (define dir (make-temporary-file "commerce-checkout-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define file (build-path dir "admission.json"))
     (call-with-output-file file (lambda (out) (write-json fixture-admission out)))
     (define admission (read-provider-admission file))
     (define store (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
     (define claims-path (build-path dir "claims.sqlite"))
     (initialize-sqlite-alipay-checkout-claims! claims-path)
     (define claim! (make-sqlite-alipay-checkout-claimer claims-path))
     (dynamic-wind
      void
      (lambda ()
        (define (create subject offer #:allow [allow (lambda (s p o u) #t)] #:key [key fixture-key]
                        #:app [app "fixture-app"] #:admission [record admission] #:request [request "request-123"]
                        #:notify [notify "https://example.test/notify"])
          (create-alipay-checkout!
           store #:service-id "publy-service" #:request-id request #:subject-id subject
           #:offer offer #:authorize allow #:claim! claim! #:admission record #:environment "sandbox"
           #:app-id app #:seller-id "fixture-seller" #:private-key key
           #:title "Publy Personal" #:notify-url notify
           #:return-url "https://example.test/return" #:timestamp "2026-10-30 12:30:00" #:at 500))
        (check-exn exn:fail? (lambda () (create "account-a" fixture-offer #:allow (lambda (s p o u) #f))))
        (define unclaimed (sqlite3-connect #:database claims-path #:mode 'read-only))
        (check-equal? (query-value unclaimed "SELECT COUNT(*) FROM alipay_checkout_claim") 0)
        (disconnect unclaimed)
        (define-values (order fields) (create "account-a" fixture-offer))
        (define saved (storage-checkout-binding-ref store order))
        (check-equal? (checkout-binding-subject-id saved) "account-a")
        (check-equal? (checkout-binding-amount-minor-units saved) 2900)
        (define business (string->jsexpr (cdr (assoc "biz_content" fields))))
        (check-equal? (hash-ref business 'out_trade_no) order)
        (check-equal? (hash-ref business 'total_amount) "29.00")
        (check-true (digest/verify (pk-key->public-only-key fixture-key) 'sha256
                                   (string->bytes/utf-8 (alipay-request-signing-content fields))
                                   (base64-decode (string->bytes/utf-8 (cdr (assoc "sign" fields))))
                                   #:pad 'pkcs1-v1.5))
        (define-values (again ignored) (create "account-a" fixture-offer))
        (check-equal? again order)
        ;; A different approved merchant must not reuse the same request's
        ;; existing binding, even if product, subject and price are identical.
        (define alternate-file (build-path dir "alternate-admission.json"))
        (call-with-output-file alternate-file
          (lambda (out) (write-json (hash-set fixture-admission 'merchant_app_id "other-app") out)))
        (define alternate-admission (read-provider-admission alternate-file))
        (check-exn exn:fail? (lambda () (create "account-a" fixture-offer
                                                #:app "other-app" #:admission alternate-admission)))
        (check-exn exn:fail? (lambda () (create "account-b" fixture-offer)))
        (check-exn exn:fail? (lambda () (create "account-a" fixture-offer #:notify "https://other.test/notify")))
        (check-exn exn:fail? (lambda () (create "account-a" (offer "publy-personal-monthly" "publy" 'one-time (money "CNY" 2900) "other-policy"))))
        (check-exn exn:fail? (lambda () (create "account-a" (offer "other-offer" "publy" 'one-time (money "CNY" 2900) "fixture-policy"))))
        (check-equal? (checkout-binding-subject-id (storage-checkout-binding-ref store order)) "account-a")
        ;; A signing error after durable binding must be retryable with the
        ;; same order, never mint a second provider order.
        (check-exn exn:fail? (lambda () (create "account-a" fixture-offer #:request "signing-failure" #:key #f)))
        (define claim-db (sqlite3-connect #:database claims-path #:mode 'read-only))
        (define persisted-orders (query-list claim-db "SELECT order_id FROM alipay_checkout_claim WHERE order_id <> ?" order))
        (disconnect claim-db)
        (check-equal? (length persisted-orders) 1)
        (define-values (recovered ignored2) (create "account-a" fixture-offer #:request "signing-failure"))
        (check-equal? recovered (car persisted-orders))
        ;; Restoring an empty claim database beside an existing Commerce order
        ;; must stop retries rather than silently re-enroll it.
        (delete-file claims-path)
        (initialize-sqlite-alipay-checkout-claims! claims-path)
        (check-exn exn:fail? (lambda () (create "account-a" fixture-offer))))
      (lambda () (storage-close store))))
   (lambda () (delete-directory/files dir))))

(test-case "claim store serializes competing requests and refuses missing state"
  (define dir (make-temporary-file "commerce-checkout-claims-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define file (build-path dir "claims.sqlite"))
     (check-exn exn:fail? (lambda () (make-sqlite-alipay-checkout-claimer file)))
     (initialize-sqlite-alipay-checkout-claims! file)
     (define claim! (make-sqlite-alipay-checkout-claimer file))
     (define order (string-append "ali" (make-string 32 #\a)))
     (define a (make-string 64 #\a))
     (define b (make-string 64 #\b))
     (define results (make-channel))
     (for ([i (in-range 8)])
       (thread (lambda () (channel-put results (cons (if (even? i) a b)
                                                    (claim! order (if (even? i) a b) #f))))))
     (define all (for/list ([i (in-range 8)]) (channel-get results)))
     (define winner (caar (filter cdr all)))
     (for ([entry (in-list all)])
       (check-equal? (cdr entry) (equal? (car entry) winner)))
     (check-false (claim! (string-append "ali" (make-string 32 #\b)) a #t))
     (delete-file file)
     (check-exn exn:fail? (lambda () (claim! order winner #t))))
   (lambda () (delete-directory/files dir))))
