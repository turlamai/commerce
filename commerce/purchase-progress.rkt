#lang racket/base

;; A trusted product backend can describe an authenticated checkout's current
;; processing state without exposing payment evidence, order PII, a claim token,
;; an issuer key or any right to unlock software. This is NOT an HTTP route;
;; the product must authenticate the user and bind the stable subject first.
(provide current-purchase-progress)

(require racket/list
         "storage.rkt"
         "private/model.rkt")

(define (refuse)
  (raise (exn:fail:commerce "Purchase scope is not authorized"
                            (current-continuation-marks)
                            'purchase-scope-denied (hash))))

(define (progress status)
  (hasheq 'status status))

(define (current-purchase-progress storage
                                   #:provider provider
                                   #:order-id order-id
                                   #:product-id product
                                   #:offer-id offer
                                   #:subject-id subject
                                   #:authorize authorize)
  (unless (commerce-storage? storage)
    (raise-argument-error 'current-purchase-progress
                          "commerce-storage?" storage))
  (unless (and (stable-id? provider) (opaque-id? order-id)
               (stable-id? product) (stable-id? offer)
               (opaque-id? subject)
               (procedure? authorize)
               (procedure-arity-includes? authorize 5))
    (raise-argument-error 'current-purchase-progress
                          "bounded provider/order/product/offer/subject and five-argument authorizer"
                          (list provider order-id product offer subject)))
  ;; Authorization is evaluated before any storage existence lookup.
  ;; A caller-provided buyer email, success redirect or paid flag is not
  ;; accepted; the product's identity service owns the subject binding.
  (unless (eq? #t (authorize provider order-id product offer subject))
    (refuse))
  (with-handlers ([exn:fail:commerce? raise]
                  [exn:fail? (lambda (_) (progress "unavailable"))])
    (define binding (storage-checkout-binding-ref storage order-id))
    (cond
      [(not binding)
       (progress "unknown-checkout")]
      [(not (and (equal? (checkout-binding-provider binding) provider)
                 (equal? (checkout-binding-merchant-external-id binding) order-id)
                 (equal? (checkout-binding-product-id binding) product)
                 (equal? (checkout-binding-offer-id binding) offer)
                 (equal? (checkout-binding-subject-id binding) subject)))
       (refuse)]
      [else
       (define order (storage-order-ref storage provider order-id))
       (cond
         [(and order
               (not (and (equal? (order-projection-offer-id order) offer)
                         (equal? (order-projection-subject-id order) subject)
                         (equal? (money-currency (order-projection-amount order))
                                 (checkout-binding-currency binding))
                         (= (money-minor-units (order-projection-amount order))
                            (checkout-binding-amount-minor-units binding)))))
          (progress "unavailable")]
         [(and order (order-projection-refunded? order))
          (progress "refunded")]
         [(storage-unresolved-refund? storage subject offer)
          (progress "refund-pending")]
         [(not order)
          (if (null? (storage-order-journal storage provider order-id))
              (progress "awaiting-payment")
              (progress "payment-processing"))]
         [(not (order-projection-paid? order))
          (progress "payment-processing")]
         [else
          (define work (storage-order-outbox storage provider order-id))
          (define issued?
            (for/or ([item (in-list work)])
              (and (eq? (issuance-outbox-item-action item) 'grant)
                   (eq? (issuance-outbox-item-status item) 'completed)
                   (storage-issued-credential-ref
                    storage (issuance-outbox-item-id item)))))
          ;; Even a completed, signed credential record does not prove that
          ;; its one-time claim was delivered or imported by the product.
          (progress (if issued? "credential-recorded"
                        "issuance-pending"))])])))
