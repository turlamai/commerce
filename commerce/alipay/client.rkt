#lang racket/base

;; Network boundary for Alipay's signed REST gateway. No credential value
;; is ever printed by the opaque client. Only fixed HTTPS endpoints are
;; allowed; responses are authenticated before they can be used as facts.
(provide
 alipay-query-client?
 make-alipay-query-client
 fetch-alipay-trade-query-response
 fetch-alipay-full-refund-query-response)

(require crypto
         crypto/libcrypto
         net/http-easy
         racket/date
         racket/port
         "../alipay.rkt"
         "refund.rkt"
         "../private/model.rkt")

(define sandbox-gateway "https://openapi-sandbox.dl.alipaydev.com/gateway.do")
(define production-gateway "https://openapi.alipay.com/gateway.do")
(define max-response-bytes 65536)
(define hex-digits "0123456789ABCDEF")

(struct alipay-query-client
  (app-id private-key alipay-public-key environment transport clock))

(define (raise-query code)
  (raise (exn:fail:commerce
          "Alipay order query failed"
          (current-continuation-marks) code (hash))))

(define (form-encode fields)
  (define out (open-output-bytes))
  (define (emit value)
    (for ([byte (in-bytes (string->bytes/utf-8 value))])
      (if (or (<= 65 byte 90) (<= 97 byte 122)
              (<= 48 byte 57) (member byte '(45 46 95 126)))
          (write-byte byte out)
          (begin
            (write-byte 37 out)
            (write-byte (char->integer (string-ref hex-digits (quotient byte 16))) out)
            (write-byte (char->integer (string-ref hex-digits (remainder byte 16))) out)))))
  (for ([entry (in-list fields)]
        [index (in-naturals)])
    (when (> index 0) (write-byte 38 out))
    (emit (car entry))
    (write-byte 61 out)
    (emit (cdr entry)))
  (get-output-bytes out))

(define (pad2 value)
  (if (< value 10) (string-append "0" (number->string value))
      (number->string value)))

(define (default-timestamp)
  ;; Alipay expects yyyy-MM-dd HH:mm:ss in China time (GMT+8).
  (define date (seconds->date (+ (current-seconds) (* 8 3600)) #f))
  (string-append (number->string (date-year date))
                 "-" (pad2 (date-month date))
                 "-" (pad2 (date-day date))
                 " " (pad2 (date-hour date))
                 ":" (pad2 (date-minute date))
                 ":" (pad2 (date-second date))))

(define (default-transport url body)
  (define response
    (post url
          #:headers
          (hash 'content-type "application/x-www-form-urlencoded;charset=utf-8")
          #:data body
          #:timeouts (make-timeout-config #:connect 5 #:request 15)
          #:max-attempts 1
          #:max-redirects 0
          #:stream? #t))
  (dynamic-wind
    void
    (lambda ()
      (define raw
        (sync/timeout
         15
         (read-bytes-evt (add1 max-response-bytes)
                         (response-output response))))
      (unless (and raw (bytes? raw)
                   (<= (bytes-length raw) max-response-bytes))
        (raise-query 'alipay-query-unavailable))
      (values (response-status-code response) raw))
    (lambda () (response-close! response))))

(define (make-alipay-query-client
         #:app-id app-id
         #:merchant-private-key merchant-private-key
         #:alipay-public-key alipay-public-key
         #:environment environment
         #:transport [transport default-transport]
         #:clock [clock default-timestamp])
  (unless (and (string? app-id) (positive? (string-length app-id))
               (private-key? merchant-private-key)
               (string? alipay-public-key)
               (positive? (string-length alipay-public-key))
               (memq environment '(sandbox production))
               (procedure? transport)
               (procedure? clock))
    (raise-arguments-error
     'make-alipay-query-client "invalid merchant query client configuration"))
  (alipay-query-client app-id merchant-private-key alipay-public-key
                       environment transport clock))

(define (fetch-alipay-trade-query-response client binding)
  (unless (alipay-query-client? client)
    (raise-argument-error 'fetch-alipay-trade-query-response
                          "alipay-query-client?" client))
  (unless (alipay-binding? binding)
    (raise-argument-error 'fetch-alipay-trade-query-response
                          "alipay-binding?" binding))
  (unless (equal? (alipay-binding-app-id binding)
                  (alipay-query-client-app-id client))
    (raise-query 'alipay-order-mismatch))
  (define gateway
    (if (eq? (alipay-query-client-environment client) 'production)
        production-gateway sandbox-gateway))
  (define params
    (make-alipay-trade-query-parameters
     binding
     (alipay-query-client-private-key client)
     #:timestamp ((alipay-query-client-clock client))))
  (define-values (status response)
    (with-handlers ([exn:fail:commerce? raise]
                    [exn:fail?
                     (lambda (_) (raise-query 'alipay-query-unavailable))])
      ((alipay-query-client-transport client) gateway (form-encode params))))
  (unless (and (exact-integer? status) (bytes? response))
    (raise-query 'alipay-query-unavailable))
  (unless (<= (bytes-length response) max-response-bytes)
    (raise-query 'alipay-query-unavailable))
  (unless (<= 200 status 299)
    (raise-query
     (if (or (= status 408) (= status 429) (<= 500 status 599))
         'alipay-query-unavailable 'alipay-query-rejected)))
  ;; Transport success is not payment success: require RSA2 signature,
  ;; complete order, status and amount proof before returning bytes.
  (verify-alipay-trade-query-response
   response (alipay-query-client-alipay-public-key client) binding)
  response)


;; Read-only refund verification endpoint. This never creates or repeats a
;; money-moving alipay.trade.refund request. The operator must use the SAME
;; persisted refund request id from the original provider refund request.
(define (fetch-alipay-full-refund-query-response client binding request-id)
  (unless (alipay-query-client? client)
    (raise-argument-error 'fetch-alipay-full-refund-query-response
                          "alipay-query-client?" client))
  (unless (alipay-binding? binding)
    (raise-argument-error 'fetch-alipay-full-refund-query-response
                          "alipay-binding?" binding))
  (unless (equal? (alipay-binding-app-id binding)
                  (alipay-query-client-app-id client))
    (raise-query 'alipay-refund-mismatch))
  (define params
    (make-alipay-full-refund-query-parameters
     binding
     (alipay-query-client-private-key client)
     request-id
     #:timestamp ((alipay-query-client-clock client))))
  (define gateway
    (if (eq? (alipay-query-client-environment client) 'production)
        production-gateway sandbox-gateway))
  (define-values (status raw)
    (with-handlers ([exn:fail:commerce? raise]
                    [exn:fail?
                     (lambda (_) (raise-query 'alipay-query-unavailable))])
      ((alipay-query-client-transport client)
       gateway (form-encode params))))
  (unless (and (exact-integer? status) (bytes? raw)
               (<= (bytes-length raw) max-response-bytes))
    (raise-query 'alipay-query-unavailable))
  (unless (<= 200 status 299)
    (raise-query
     (if (or (= status 408) (= status 429) (<= 500 status 599))
         'alipay-query-unavailable 'alipay-query-rejected)))
  (verify-alipay-full-refund-query-response
   raw
   (alipay-query-client-alipay-public-key client)
   binding request-id)
  raw)
