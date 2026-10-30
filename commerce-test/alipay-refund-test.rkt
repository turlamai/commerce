#lang racket/base

(require base64
         commerce
         commerce/alipay
         commerce/alipay/refund
         commerce/provider
         commerce/journal
         commerce/storage
         commerce/storage/sqlite
         racket/file
         crypto
         crypto/libcrypto
         json
         rackunit)

(define key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))

(define public
  (string-append
   "-----BEGIN PUBLIC KEY-----\n"
   (bytes->string/utf-8
    (base64-encode
     (pk-key->datum (pk-key->public-only-key key) 'SubjectPublicKeyInfo)
     #:line #f))
   "\n-----END PUBLIC KEY-----\n"))

(define binding
  (alipay-binding "2026000000000000" "2088000000000000"
                  "order_test_001" "taskly-pro-lifetime"
                  "subject-1" (money "CNY" 1234)))

(define (code? symbol)
  (lambda (e)
    (and (exn:fail:commerce? e)
         (eq? (exn:fail:commerce-code e) symbol))))

(define (signed-response data)
  (define raw (jsexpr->string data))
  (define sig
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign key 'sha256 (string->bytes/utf-8 raw)
                   #:pad 'pkcs1-v1.5)))
  (string->bytes/utf-8
   (string-append
    "{\"alipay_trade_fastpay_refund_query_response\":"
    raw
    ",\"sign\":\""
    (bytes->string/utf-8 (base64-encode sig #:line #f))
    "\"}")))

(define (response #:amount [amount "12.34"]
                  #:status [status "REFUND_SUCCESS"]
                  #:request-id [request-id "refund_001"]
                  #:order-id [order-id "order_test_001"]
                  #:code [code "10000"])
  (signed-response
   (hasheq 'code code
           'out_trade_no order-id
           'trade_no "202610301234567890"
           'out_request_no request-id
           'refund_amount amount
           'refund_status status
           'gmt_refund_pay "2026-10-30 13:45:00")))

(test-case "RSA2 request signatures cover exact refund amount and request id"
  (define params
    (make-alipay-full-refund-parameters
     binding key "refund_001"
     #:timestamp "2026-10-30 12:30:00"
     #:amount-fen 1234))
  (check-equal? (cdr (assoc "method" params)) "alipay.trade.refund")
  (define content (string->jsexpr (cdr (assoc "biz_content" params))))
  (check-equal? (hash-ref content 'refund_amount) "12.34")
  (check-equal? (hash-ref content 'out_request_no) "refund_001")
  (check-true
   (digest/verify
    (pk-key->public-only-key key) 'sha256
    (string->bytes/utf-8 (alipay-signing-content params))
    (base64-decode (string->bytes/utf-8 (cdr (assoc "sign" params))))
    #:pad 'pkcs1-v1.5))
  (check-exn (code? 'alipay-partial-refund-unsupported)
             (lambda ()
               (make-alipay-full-refund-parameters
                binding key "refund_002"
                #:timestamp "2026-10-30 12:30:00"
                #:amount-fen 1000))))

(test-case "full refund query only confirms REFUND_SUCCESS"
  (define params
    (make-alipay-full-refund-query-parameters
     binding key "refund_001"
     #:timestamp "2026-10-30 12:31:00"))
  (check-equal? (cdr (assoc "method" params))
                "alipay.trade.fastpay.refund.query")
  (define confirmed
    (verify-alipay-full-refund-query-response
     (response) public binding "refund_001"))
  (check-equal? (alipay-full-refund-proof-amount confirmed) 1234)
  (check-equal? (alipay-full-refund-proof-request-id confirmed) "refund_001")
  (check-true (exact-nonnegative-integer?
               (alipay-full-refund-proof-refunded-at confirmed)))
  (check-exn
   (code? 'alipay-refund-pending)
   (lambda ()
     (verify-alipay-full-refund-query-response
      (response #:status "PROCESSING")
      public binding "refund_001")))
  (check-exn
   (code? 'alipay-refund-mismatch)
   (lambda ()
     (verify-alipay-full-refund-query-response
      (response #:amount "12.33")
      public binding "refund_001")))
  (check-exn
   (code? 'alipay-refund-mismatch)
   (lambda ()
     (verify-alipay-full-refund-query-response
      (response #:request-id "refund_other")
      public binding "refund_001")))
  (check-exn
   (code? 'alipay-refund-query-rejected)
   (lambda ()
     (verify-alipay-full-refund-query-response
      (response #:code "40004")
      public binding "refund_001")))
  (define raw (response))
  (define altered
    (bytes-append (subbytes raw 0 (sub1 (bytes-length raw)))
                  #",\"extra\":1}"))
  (check-exn
   (code? 'alipay-query-invalid)
   (lambda ()
     (verify-alipay-full-refund-query-response
      altered public binding "refund_001"))))


(test-case "confirmed full refund journals once and projects a withdrawal"
  (define temp-dir (make-temporary-file "commerce-alipay-refund-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage
       (open-sqlite-commerce-storage (build-path temp-dir "commerce.sqlite")))
     (dynamic-wind
      void
      (lambda ()
        (define paid-raw #"synthetic-authenticated-paid-event")
        (define paid
          (make-verified-payment-event
           "alipay" "notify_test_001"
           (bytes->hex-string
             (parameterize ([crypto-factories (list libcrypto-factory)])
               (digest 'sha256 paid-raw)))
           'payment-succeeded "order_test_001" "taskly-pro-lifetime"
           "subject-1" (money "CNY" 1234) 1793334600))
        (journal-accept! storage paid-raw paid #:received-at 1)
        (storage-project-next! storage #:processed-at 2)
        (define refund-raw (response))
        (define result
          (journal-alipay-full-refund!
           storage refund-raw public binding "refund_001"
           #:received-at 3))
        (check-eq? (journal-acceptance-disposition result) 'accepted)
        (define again
          (journal-alipay-full-refund!
           storage refund-raw public binding "refund_001"
           #:received-at 4))
        (check-eq? (journal-acceptance-disposition again) 'replayed)
        (storage-project-next! storage #:processed-at 5)
        (define order (storage-order-ref storage "alipay" "order_test_001"))
        (check-true (order-projection-refunded? order))
        (define disallowed
          (signed-response
           (hasheq 'code "10000"
                   'trade_no "202610301234567890"
                   'out_trade_no "order_test_001"
                   'out_request_no "refund_001"
                   'refund_amount "12.34"
                   'refund_status "REFUND_SUCCESS")))
        ;; Missing a refund settlement timestamp is NOT authority to use
        ;; the local receipt time, since that would break replay identity.
        (check-exn
         (code? 'alipay-refund-time-unknown)
         (lambda ()
           (journal-alipay-full-refund!
            storage disallowed public binding "refund_001"
            #:received-at 6))))
      (lambda () (storage-close storage))))
   (lambda () (delete-directory/files temp-dir))))
