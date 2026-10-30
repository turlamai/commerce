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
 alipay-full-refund-proof-amount
 alipay-full-refund-proof-refunded-at
 journal-alipay-full-refund!)

(require base64
         file/sha1
         crypto
         crypto/libcrypto
         json
         racket/format
         racket/string
         racket/date
         "../alipay.rkt"
         "../journal.rkt"
         "../storage.rkt"
         "../provider.rkt"
         "../private/model.rkt")

(struct alipay-full-refund-proof (order-id trade-id request-id amount refunded-at))

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
  (define refunded-at (hash-ref obj 'gmt_refund_pay #f))
  (alipay-full-refund-proof order-id trade-id actual-id amount
                            (and refunded-at (refund-time->epoch refunded-at))))


;; Calendar conversion uses GMT+8 explicitly; callbacks or query retries
;; must never use their arbitrary receive time as event occurrence.
(define (refund-time->epoch value)
  (define parts
    (and (string? value)
         (regexp-match
          #px"^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$"
          value)))
  (unless parts (fail 'alipay-refund-time-invalid))
  (define ns (map string->number (cdr parts)))
  (define-values (year month day hour minute second) (apply values ns))
  (unless (and (<= 2000 year 2100) (<= 1 month 12)
               (<= 1 day 31) (<= 0 hour 23)
               (<= 0 minute 59) (<= 0 second 59))
    (fail 'alipay-refund-time-invalid))
  (define tm (find-seconds second minute hour day month year #f))
  (define d (seconds->date tm #f))
  (unless (and (= (date-year d) year) (= (date-month d) month)
               (= (date-day d) day) (= (date-hour d) hour)
               (= (date-minute d) minute) (= (date-second d) second))
    (fail 'alipay-refund-time-invalid))
  (- tm (* 8 3600)))

;; This does NOT initiate a refund: it durably records a previously executed,
;; signed, full-refund query with the original payment's bound Offer/subject.
;; Issuer withdrawal is still an asynchronous projector/outbox consequence.
(define (journal-alipay-full-refund! storage raw alipay-public-key
                                    binding request-id
                                    #:received-at received-at)
  (unless (commerce-storage? storage)
    (raise-argument-error 'journal-alipay-full-refund!
                          "commerce-storage?" storage))
  (unless (bytes? raw)
    (raise-argument-error 'journal-alipay-full-refund! "bytes?" raw))
  (unless (exact-nonnegative-integer? received-at)
    (raise-argument-error 'journal-alipay-full-refund!
                          "exact-nonnegative-integer?" received-at))
  (define proof
    (verify-alipay-full-refund-query-response
     raw alipay-public-key binding request-id))
  (define refunded-at (alipay-full-refund-proof-refunded-at proof))
  (unless refunded-at
    (fail 'alipay-refund-time-unknown))
  (define order
    (storage-order-ref storage "alipay" (alipay-binding-order-id binding)))
  (unless (and order (order-projection-paid? order)
               (equal? (order-projection-offer-id order)
                       (alipay-binding-offer-id binding))
               (equal? (order-projection-subject-id order)
                       (alipay-binding-subject-id binding))
               (equal? (order-projection-amount order)
                       (alipay-binding-amount binding)))
    (fail 'alipay-refund-order-unpaid))
  (define event
    (make-verified-payment-event
     "alipay" (string-append "refund:" request-id)
     (bytes->hex-string (sha256-bytes raw))
     'payment-refunded
     (alipay-binding-order-id binding)
     (alipay-binding-offer-id binding)
     (alipay-binding-subject-id binding)
     (alipay-binding-amount binding)
     refunded-at))
  (journal-accept! storage raw event #:received-at received-at))
