#lang racket/base

;; Trusted in-process composition only. No network authentication, checkout
;; endpoint or payment/entitlement assertion is provided by this module.
(provide create-alipay-checkout!)

(require file/sha1 racket/port
         "../main.rkt" "../admission.rkt" "../alipay.rkt"
         "../storage.rkt" "../private/model.rkt")

(define (fail code message)
  (raise (exn:fail:commerce message (current-continuation-marks) code (hash))))

(define (bounded-id? value)
  (and (string? value) (<= 1 (string-length value) 256)
       (not (regexp-match? #px"[\r\n]" value))))

;; Length framing avoids collisions between different service/request pairs.
;; This ID is an opaque correlation handle, never an authentication token.
(define (framed-digest domain values)
  (define framed
    (call-with-output-bytes
     (lambda (out)
       (write-bytes (string->bytes/utf-8 domain) out)
       (for ([v (in-list values)])
         (define b (string->bytes/utf-8 v))
         (write-bytes (string->bytes/utf-8 (format "~a:" (bytes-length b))) out)
         (write-bytes b out)))))
  (bytes->hex-string (sha256-bytes framed)))

(define (order-id service request)
  (string-append "ali" (substring (framed-digest "commerce-alipay-order-v1\n" (list service request)) 0 32)))

(define (create-alipay-checkout! storage
          #:service-id service #:request-id request #:subject-id subject
          #:offer offer #:authorize authorize #:claim! claim! #:admission admission
          #:environment environment #:app-id app #:seller-id seller
          #:private-key private-key #:title title #:notify-url notify-url
          #:return-url return-url #:timestamp timestamp #:at now)
  (unless (and (commerce-storage? storage) (bounded-id? service) (bounded-id? request)
               (bounded-id? subject) (offer? offer) (eq? (offer-kind offer) 'one-time)
               (bounded-id? title) (bounded-id? notify-url) (bounded-id? return-url)
               (procedure-arity-includes? authorize 4) (procedure-arity-includes? claim! 3))
    (fail 'checkout-invalid "Invalid trusted checkout inputs"))
  ;; Only literal #t from a trusted caller permits a scope. Authorization and
  ;; the provider's exact merchant/Offer/price gate precede any database write.
  (unless (eq? #t (authorize service (offer-product-id offer) (offer-id offer) subject))
    (fail 'checkout-unauthorized "Checkout scope is not authorized"))
  (authorize-provider-checkout!
   admission #:provider "alipay" #:environment environment #:merchant-app-id app
   #:seller-id seller #:product-id (offer-product-id offer) #:offer-id (offer-id offer)
   #:payment-method "alipay" #:transaction-type "one-time" #:amount (offer-price offer) #:at now)
  (define id (order-id service request))
  (define desired
    (checkout-binding id "alipay" (offer-product-id offer) (offer-id offer) subject
                      (money-currency (offer-price offer)) (money-minor-units (offer-price offer)) 2))
  ;; The general binding does not include merchant or environment. A separate
  ;; durable claim pins the full request before creating the binding. A lost
  ;; claim beside an existing order must be reconciled, never recreated.
  (define fingerprint
    (framed-digest "commerce-alipay-claim-v1\n"
                   (list service request environment app seller (offer-product-id offer)
                         (offer-id offer) (offer-entitlement-policy-id offer) subject
                         (money-currency (offer-price offer))
                         (number->string (money-minor-units (offer-price offer)))
                         title notify-url return-url)))
  (define already-bound? (and (storage-checkout-binding-ref storage id) #t))
  (unless (eq? #t (claim! id fingerprint already-bound?))
    (fail 'checkout-conflict "Checkout claim is inconsistent or unavailable"))
  ;; A competing retry can win the INSERT. Only accept it when every persisted
  ;; binding field matches; otherwise fail closed without altering evidence.
  (with-handlers ([exn:fail?
                   (lambda (err)
                     (define existing (storage-checkout-binding-ref storage id))
                     (cond [(equal? existing desired) (void)]
                           [existing (fail 'checkout-conflict "Checkout request conflicts with existing binding")]
                           [else (raise err)]))])
    (storage-create-checkout-binding! storage desired #:created-at now))
  (define fields
    (make-alipay-page-pay-parameters
     (alipay-binding app seller id (offer-id offer) subject (offer-price offer)) private-key
     #:title title #:notify-url notify-url #:return-url return-url #:timestamp timestamp))
  (values id fields))
