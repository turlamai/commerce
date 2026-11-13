#lang racket/base

;; ADR-0019: a deployment-owned, provider-scoped checkout admission gate.
;; It is never proof that a provider approved an account: the human operator
;; must corroborate the private references against actual merchant records.
;; This module cannot initiate a charge or construct payment evidence.
(provide provider-admission?
         read-provider-admission
         authorize-provider-checkout!)

(require racket/file
         racket/list
         permit/json
         "private/model.rkt")

(struct checkout-capability (offer product method kind currency price min max))
(struct provider-admission
  (provider environment app seller approved-at expires-at capabilities))

(define (refuse)
  (raise
   (exn:fail:commerce "Provider checkout is not admitted"
                      (current-continuation-marks)
                      'provider-not-admitted (hash))))

(define (exact-fields? obj names)
  (and (hash? obj)
       (equal? (sort (hash-keys obj) symbol<?) (sort names symbol<?))))

(define (bounded? value [max-length 256])
  (and (string? value)
       (<= 1 (string-length value) max-length)
       (not (regexp-match? #px"[\r\n]" value))))

(define (valid-count? n)
  (and (exact-nonnegative-integer? n) (<= n 999999999999)))

(define root-fields
  '(admission_reference approved_at capabilities checkout_api
    cost_reference environment expires_at merchant_app_id
    product_category provider read_api seller_id version))
(define cap-fields
  '(amount_minor currency max_minor method min_minor
    offer_id product_id transaction_type))

(define (parse-capability obj)
  (unless (exact-fields? obj cap-fields) (refuse))
  (define offer (hash-ref obj 'offer_id))
  (define product (hash-ref obj 'product_id))
  (define method (hash-ref obj 'method))
  (define kind (hash-ref obj 'transaction_type))
  (define currency (hash-ref obj 'currency))
  (define price (hash-ref obj 'amount_minor))
  (define lower (hash-ref obj 'min_minor))
  (define upper (hash-ref obj 'max_minor))
  (unless (and (stable-id? offer) (stable-id? product)
               (stable-id? method)
               (member kind '("one-time" "subscription"))
               (regexp-match? #px"^[A-Z]{3}$" currency)
               (valid-count? price) (positive? price)
               (valid-count? lower) (valid-count? upper)
               (<= 1 lower price upper))
    (refuse))
  (checkout-capability offer product method kind currency
                       price lower upper))

(define (read-provider-admission path)
  (unless (path-string? path)
    (raise-argument-error 'read-provider-admission "path-string?" path))
  ;; Missing, oversized, malformed, duplicate-key or unapproved records
  ;; refuse before any network call or database checkout binding is made.
  (with-handlers ([exn:fail:commerce? raise]
                  [exn:fail? (lambda (_) (refuse))])
    (define content (file->bytes path))
    (unless (<= 1 (bytes-length content) 65536) (refuse))
    (define record (read-json-bytes/strict 'read-provider-admission content))
    (unless (exact-fields? record root-fields) (refuse))
    (define (r field) (hash-ref record field))
    (unless (and (equal? (r 'version) 1)
                 (stable-id? (r 'provider))
                 (member (r 'environment) '("sandbox" "production"))
                 (bounded? (r 'merchant_app_id))
                 (bounded? (r 'seller_id))
                 (bounded? (r 'product_category))
                 (bounded? (r 'admission_reference))
                 (bounded? (r 'cost_reference))
                 (bounded? (r 'checkout_api))
                 (bounded? (r 'read_api))
                 (exact-nonnegative-integer? (r 'approved_at))
                 (exact-nonnegative-integer? (r 'expires_at))
                 (< (r 'approved_at) (r 'expires_at))
                 (list? (r 'capabilities))
                 (<= 1 (length (r 'capabilities)) 200))
      (refuse))
    (define caps (map parse-capability (r 'capabilities)))
    (define identity
      (lambda (cap)
        (list (checkout-capability-offer cap)
              (checkout-capability-product cap)
              (checkout-capability-method cap)
              (checkout-capability-kind cap)
              (checkout-capability-currency cap))))
    (unless (= (length caps)
               (length (remove-duplicates (map identity caps))))
      (refuse))
    ;; Alipay's current supported boundary is CNY one-time page pay only;
    ;; it must not accidentally admit subscriptions or an unrelated API.
    (when (equal? (r 'provider) "alipay")
      (unless (and (equal? (r 'checkout_api) "alipay.trade.page.pay")
                   (equal? (r 'read_api) "alipay.trade.query")
                   (for/and ([cap (in-list caps)])
                     (and (equal? (checkout-capability-currency cap) "CNY")
                          (equal? (checkout-capability-kind cap) "one-time")
                          (equal? (checkout-capability-method cap) "alipay"))))
        (refuse)))
    (provider-admission
     (r 'provider) (r 'environment)
     (r 'merchant_app_id) (r 'seller_id)
     (r 'approved_at) (r 'expires_at) caps)))

(define (authorize-provider-checkout! admission
                                      #:provider provider
                                      #:environment environment
                                      #:merchant-app-id app
                                      #:seller-id seller
                                      #:product-id product
                                      #:offer-id offer
                                      #:payment-method method
                                      #:transaction-type transaction
                                      #:amount amount
                                      #:at [now (current-seconds)])
  (unless (provider-admission? admission)
    (raise-argument-error 'authorize-provider-checkout!
                          "provider-admission?" admission))
  (unless (and (money? amount) (exact-nonnegative-integer? now))
    (refuse))
  (unless
      (and (equal? (provider-admission-provider admission) provider)
           (equal? (provider-admission-environment admission) environment)
           (equal? (provider-admission-app admission) app)
           (equal? (provider-admission-seller admission) seller)
           (<= (provider-admission-approved-at admission) now)
           (< now (provider-admission-expires-at admission))
           (for/or ([cap (in-list (provider-admission-capabilities admission))])
             (and (equal? (checkout-capability-product cap) product)
                  (equal? (checkout-capability-offer cap) offer)
                  (equal? (checkout-capability-method cap) method)
                  (equal? (checkout-capability-kind cap) transaction)
                  (equal? (checkout-capability-currency cap)
                          (money-currency amount))
                  (= (checkout-capability-price cap)
                     (money-minor-units amount))
                  (<= (checkout-capability-min cap)
                      (money-minor-units amount)
                      (checkout-capability-max cap)))))
    (refuse))
  (void))
