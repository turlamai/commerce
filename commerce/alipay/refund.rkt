#lang racket/base

;; Full-amount refund request and independently signed refund-query proof.
;; Partial refunds require a separate cumulative-refund ledger; do not map
;; partial refunds to Commerce's existing binary refunded? projection.
(provide
 make-alipay-full-refund-parameters
 make-alipay-full-refund-query-parameters
 verify-alipay-full-refund-query-response
 alipay-full-refund-proof?
 alipay-full-refund-proof-order-id
 alipay-full-refund-proof-trade-id
 alipay-full-refund-proof-request-id
 alipay-full-refund-proof-amount)

(require base64
         crypto
         crypto/libcrypto
         json
         racket/format
         racket/string
         "../alipay.rkt"
         "../private/model.rkt")

(struct alipay-full-refund-proof (order-id trade-id request-id amount))

(define (fail code)
  (raise (exn:fail:commerce
          "Alipay refund rejected"
          (current-continuation-marks) code (hash))))

(define (refund-id? value)
  (and (string? value)
       (regexp-match? #px"^[A-Za-z0-9_-]{1,64}$" value)))

(define (minor->cny value)
  (string-append (number->string (quotient value 100))
                 "." (~r (remainder value 100)
                          #:min-width 2 #:pad-string "0")))

(define (signed-parameters binding key method biz timestamp)
  (unless (and (alipay-binding? binding) (private-key? key)
               (string? timestamp)
               (regexp-match?
                #px"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"
                timestamp))
    (fail 'alipay-refund-request-invalid))
  (define fields
    (list (cons "app_id" (alipay-binding-app-id binding))
          (cons "method" method)
          (cons "format" "JSON")
          (cons "charset" "utf-8")
          (cons "sign_type" "RSA2")
          (cons "timestamp" timestamp)
          (cons "version" "1.0")
          (cons "biz_content" (jsexpr->string biz))))
  (define signature
    (with-handlers ([exn:fail?
                     (lambda (_) (fail 'alipay-refund-signature-unavailable))])
      (parameterize ([crypto-factories (list libcrypto-factory)])
        (digest/sign key 'sha256
                     (string->bytes/utf-8
                      (alipay-signing-content fields))
                     #:pad 'pkcs1-v1.5))))
  (cons (cons "sign"
              (bytes->string/utf-8
               (base64-encode signature #:line #f)))
        fields))

(define (make-alipay-full-refund-parameters binding key request-id
                                            #:timestamp timestamp
                                            #:amount-fen amount-fen)
  (unless (and (alipay-binding? binding)
               (refund-id? request-id)
               (exact-positive-integer? amount-fen))
    (fail 'alipay-refund-request-invalid))
  (unless (= amount-fen (money-minor-units (alipay-binding-amount binding)))
    (fail 'alipay-partial-refund-unsupported))
  (signed-parameters
   binding key "alipay.trade.refund"
   (hasheq 'out_trade_no (alipay-binding-order-id binding)
           'out_request_no request-id
           'refund_amount (minor->cny amount-fen))
   timestamp))

(define (make-alipay-full-refund-query-parameters binding key request-id
                                                  #:timestamp timestamp)
  (unless (and (alipay-binding? binding) (refund-id? request-id))
    (fail 'alipay-refund-request-invalid))
  (signed-parameters
   binding key "alipay.trade.fastpay.refund.query"
   (hasheq 'out_trade_no (alipay-binding-order-id binding)
           'out_request_no request-id)
   timestamp))

(define (verify-alipay-full-refund-query-response raw public-key-pem
                                                  binding request-id)
  (unless (and (alipay-binding? binding) (refund-id? request-id))
    (fail 'alipay-refund-request-invalid))
  (define obj
    (verify-alipay-signed-api-response
     raw public-key-pem "alipay_trade_fastpay_refund_query_response"))
  (define (required key)
    (define value (hash-ref obj key #f))
    (unless (and (string? value) (positive? (string-length value)))
      (fail 'alipay-refund-query-invalid))
    value)
  (unless (equal? (required 'code) "10000")
    (fail 'alipay-refund-query-rejected))
  (unless (equal? (hash-ref obj 'refund_status #f) "REFUND_SUCCESS")
    ;; HTTP 200 and code 10000 are NOT proof of a successful refund.
    (fail 'alipay-refund-pending))
  (define order-id (required 'out_trade_no))
  (define trade-id (required 'trade_no))
  (define actual-id (required 'out_request_no))
  (define amount (alipay-cny->fen (required 'refund_amount)))
  (unless (and (equal? order-id (alipay-binding-order-id binding))
               (equal? actual-id request-id)
               (= amount (money-minor-units (alipay-binding-amount binding))))
    (fail 'alipay-refund-mismatch))
  (alipay-full-refund-proof order-id trade-id actual-id amount))
