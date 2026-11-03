#lang racket/base

(require rackunit
         json
         racket/file
         commerce
         commerce/admission)

;; Deliberately synthetic: the fixture is not proof of merchant admission.
(define capability
  (hasheq 'offer_id "taskly-pro-lifetime"
          'product_id "taskly"
          'method "alipay"
          'transaction_type "one-time"
          'currency "CNY"
          'amount_minor 1234
          'min_minor 100
          'max_minor 100000))

(define (record [caps (list capability)])
  (hasheq 'version 1
          'provider "alipay"
          'environment "sandbox"
          'merchant_app_id "synthetic-app-001"
          'seller_id "synthetic-seller-001"
          'product_category "approved-desktop-fixture"
          'admission_reference "private-operator-fixture-001"
          'cost_reference "private-fee-fixture-001"
          'checkout_api "alipay.trade.page.pay"
          'read_api "alipay.trade.query"
          'approved_at 1700000000
          'expires_at 1899999999
          'capabilities caps))

(define (with-document body proc)
  (define dir (make-temporary-file "commerce-admission-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define path (build-path dir "admission.json"))
     (call-with-output-file path
       (lambda (out) (write-bytes body out)) #:exists 'truncate/replace)
     (proc path))
   (lambda () (delete-directory/files dir))))

(define (check-refused thunk)
  (check-exn
   (lambda (e)
     (and (exn:fail:commerce? e)
          (eq? (exn:fail:commerce-code e) 'provider-not-admitted)))
   thunk))

(define (admit admission
               #:provider [provider "alipay"]
               #:environment [environment "sandbox"]
               #:app [app "synthetic-app-001"]
               #:seller [seller "synthetic-seller-001"]
               #:product [product "taskly"]
               #:offer [offer "taskly-pro-lifetime"]
               #:method [method "alipay"]
               #:kind [kind "one-time"]
               #:price [price (money "CNY" 1234)]
               #:at [at 1793692800])
  (authorize-provider-checkout!
   admission #:provider provider #:environment environment
   #:merchant-app-id app #:seller-id seller
   #:product-id product #:offer-id offer
   #:payment-method method #:transaction-type kind #:amount price
   #:at at))

(test-case "approved, exact synthetic offer is admitted without charging"
  (with-document
   (jsexpr->bytes (record))
   (lambda (path)
     (define admission (read-provider-admission path))
     (check-true (provider-admission? admission))
     (check-void (admit admission))
     (check-refused (lambda () (admit admission #:provider "pancake")))
     (check-refused (lambda () (admit admission #:environment "production")))
     (check-refused (lambda () (admit admission #:app "other-app")))
     (check-refused (lambda () (admit admission #:seller "other-seller")))
     (check-refused (lambda () (admit admission #:product "movebit")))
     (check-refused (lambda () (admit admission #:offer "other-offer")))
     (check-refused (lambda () (admit admission #:method "card")))
     (check-refused (lambda () (admit admission #:kind "subscription")))
     (check-refused (lambda () (admit admission #:price (money "CNY" 1235))))
     (check-refused (lambda () (admit admission #:price (money "USD" 1234))))
     (check-refused (lambda () (admit admission #:at 1899999999)))
     (check-refused (lambda () (admit admission #:at 1600000000))))))

(test-case "missing and malformed admission documents fail closed"
  (with-document
   (jsexpr->bytes (record))
   (lambda (path)
     (delete-file path)
     (check-refused (lambda () (read-provider-admission path)))))
  (for ([raw (in-list
              (list #""
                    #"not JSON"
                    #"{\"version\":1,\"version\":1,\"provider\":\"alipay\"}"
                    (jsexpr->bytes (hash-set (record) 'extra "unknown"))
                    (jsexpr->bytes (hash-set (record) 'admission_reference ""))
                    (jsexpr->bytes (hash-set (record) 'cost_reference ""))
                    (jsexpr->bytes (hash-set (record) 'checkout_api "other"))
                    (jsexpr->bytes (hash-set (record) 'read_api "other"))
                    (jsexpr->bytes (hash-set (record) 'environment "live"))
                    (jsexpr->bytes (hash-set (record) 'expires_at 1))
                    (jsexpr->bytes (record '()))))])
    (with-document
     raw (lambda (path)
           (check-refused (lambda () (read-provider-admission path)))))))

(test-case "ambiguous, unpriced, partial and recurring offers fail closed"
  (for ([bad-cap
         (in-list
          (list
           (hash-set capability 'amount_minor 0)
           (hash-set capability 'amount_minor 1235)
           (hash-set capability 'max_minor 1000)
           (hash-set capability 'currency "USD")
           (hash-set capability 'transaction_type "subscription")
           (hash-set capability 'method "card")
           (hash-set capability 'extra "unknown")))])
    (with-document
     (jsexpr->bytes (record (list bad-cap)))
     (lambda (path)
       (if (equal? (hash-ref bad-cap 'amount_minor #f) 1235)
           (check-refused
            (lambda () (admit (read-provider-admission path))))
           (check-refused (lambda () (read-provider-admission path)))))))
  (with-document
   (jsexpr->bytes (record (list capability capability)))
   (lambda (path) (check-refused (lambda () (read-provider-admission path))))))

(test-case "admission diagnostics remain redacted"
  (with-document
   (jsexpr->bytes (record))
   (lambda (path)
     (define admission (read-provider-admission path))
     (check-false
      (regexp-match? #rx"synthetic-seller-001" (format "~v" admission)))
     (check-false
      (regexp-match? #rx"private-operator-fixture-001" (format "~s" admission))))))
