#lang racket/base

(require base64
         commerce
         commerce/alipay/server
         commerce/alipay/client
         commerce/journal
         commerce/storage
         commerce/storage/sqlite
         crypto
         crypto/libcrypto
         json
         commerce/alipay
         rackunit
         racket/file
         racket/list
         racket/string)

;; Generate fixture key material during the test, never commit a private key
;; or accept a string that has not actually passed RSA2 verification.
;; Independently reconstruct the OpenAPI request string, including sign_type.
(define (test-request-content fields)
  (string-join
   (for/list ([p (in-list (sort fields string<? #:key car))]
              #:unless (or (equal? (car p) "sign") (string=? (cdr p) "")))
     (string-append (car p) "=" (cdr p)))
   "&"))

(define rsa-private-key
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (generate-private-key (get-pk 'rsa) '((nbits 2048)))))

(define (public-key->pem key)
  (string-append
   "-----BEGIN PUBLIC KEY-----\n"
   (bytes->string/utf-8
    (base64-encode (pk-key->datum key 'SubjectPublicKeyInfo) #:line #f))
   "\n-----END PUBLIC KEY-----\n"))

(define public-key
  (public-key->pem (pk-key->public-only-key rsa-private-key)))

(define unsigned-fields
  (list (cons "total_amount" "12.34")
        (cons "seller_id" "2088000000000000")
        (cons "out_trade_no" "order_test_001")
        (cons "app_id" "2026000000000000")
        (cons "notify_id" "notify_test_001")
        (cons "gmt_payment" "2026-10-30 12:30:00")
        (cons "trade_no" "202610301234567890")
        (cons "trade_status" "TRADE_SUCCESS")
        (cons "sign_type" "RSA2")))

(define signed-fields
  (cons
   (cons "sign"
         (bytes->string/utf-8
          (base64-encode
           (parameterize ([crypto-factories (list libcrypto-factory)])
             (digest/sign rsa-private-key 'sha256
                          (string->bytes/utf-8
                           (alipay-signing-content unsigned-fields))
                          #:pad 'pkcs1-v1.5))
           #:line #f)))
   unsigned-fields))

(define (code? code)
  (lambda (e)
    (and (exn:fail:commerce? e)
         (eq? (exn:fail:commerce-code e) code))))

(define binding
  (alipay-binding "2026000000000000" "2088000000000000"
                  "order_test_001" "taskly-pro-lifetime"
                  "subject-1" (money "CNY" 1234)))
(define (signed-query-response
         #:app [app "2026000000000000"]
         #:seller [seller "2088000000000000"]
         #:order [order "order_test_001"]
         #:trade [trade "202610301234567890"]
         #:status [status "TRADE_SUCCESS"]
         #:amount [amount "12.34"]
         #:code [code "10000"])
  (define json-content
    (jsexpr->string
     (hasheq 'code code
             'app_id app
             'seller_id seller
             'out_trade_no order
             'trade_no trade
             'trade_status status
             'total_amount amount)))
  (define signature
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (digest/sign rsa-private-key 'sha256
                   (string->bytes/utf-8 json-content)
                   #:pad 'pkcs1-v1.5)))
  (string->bytes/utf-8
   (string-append
    "{\"alipay_trade_query_response\":"
    json-content
    ",\"sign\":\""
    (bytes->string/utf-8 (base64-encode signature #:line #f))
    "\"}")))

(define queried
  (verify-alipay-trade-query-response
   (signed-query-response) public-key binding))

(test-case "RSA2 fixture and exact canonical representation"
  (check-equal?
   (alipay-signing-content signed-fields)
   (string-append
    "app_id=2026000000000000&gmt_payment=2026-10-30 12:30:00"
    "&notify_id=notify_test_001"
    "&out_trade_no=order_test_001&seller_id=2088000000000000"
    "&total_amount=12.34&trade_no=202610301234567890"
    "&trade_status=TRADE_SUCCESS"))
  (define n (verify-alipay-notification signed-fields public-key))
  (check-equal? (alipay-notification-amount n) 1234)
  (define event
    (confirm-alipay-onetime-payment
     n binding queried
     #:payload-digest (make-string 64 #\a)
     #:occurred-at 1793376000))
  (check-equal? (payment-event-provider event) "alipay")
  (check-equal? (payment-event-offer-id event) "taskly-pro-lifetime")
  (check-equal? (payment-event-subject-id event) "subject-1"))

(test-case "amount parsing is integer and rejects ambiguous spellings"
  (for ([pair (in-list '(("0" . 0) ("0.01" . 1)
                         ("12.3" . 1230) ("12.34" . 1234)))])
    (check-equal? (alipay-cny->fen (car pair)) (cdr pair)))
  (for ([bad '("1.001" "-1" "+1" "01.00" "1e2" "1,00"
               "1.2 " "NaN" "")])
    (check-exn (code? 'alipay-amount-invalid)
               (lambda () (alipay-cny->fen bad)))))

(test-case "duplicate and changed fields fail closed"
  (check-exn (code? 'alipay-duplicate-field)
             (lambda () (verify-alipay-notification
                         (cons (cons "app_id" "evil") signed-fields)
                         public-key)))
  (check-exn (code? 'alipay-signature-invalid)
             (lambda ()
               (verify-alipay-notification
                (map (lambda (p)
                       (if (equal? (car p) "total_amount")
                           (cons "total_amount" "12.35") p))
                     signed-fields)
                public-key)))
  (check-exn (code? 'alipay-signature-invalid)
             (lambda ()
               (verify-alipay-notification
                (map (lambda (p)
                       (if (equal? (car p) "sign_type")
                           (cons "sign_type" "MD5") p))
                     signed-fields)
                public-key))))

(test-case "a signed query must match the immutable merchant binding"
  (define n (verify-alipay-notification signed-fields public-key))
  (for ([raw (in-list
              (list
               (signed-query-response #:app "wrong-app")
               (signed-query-response #:seller "wrong-seller")
               (signed-query-response #:order "wrong-order")
               (signed-query-response #:amount "12.35")))])
    (check-exn
     (code? 'alipay-order-mismatch)
     (lambda ()
       (verify-alipay-trade-query-response raw public-key binding))))
  (check-exn
   (code? 'alipay-query-rejected)
   (lambda ()
     (verify-alipay-trade-query-response
      (signed-query-response #:code "40004") public-key binding)))
  (define waiting
    (verify-alipay-trade-query-response
     (signed-query-response #:status "WAIT_BUYER_PAY") public-key binding))
  (check-exn
   (code? 'alipay-order-mismatch)
   (lambda ()
     (confirm-alipay-onetime-payment
      n binding waiting
      #:payload-digest (make-string 64 #\a)
      #:occurred-at 1793376000)))
  (define raw (signed-query-response))
  (check-exn
   (code? 'alipay-query-signature-invalid)
   (lambda ()
     (verify-alipay-trade-query-response
      (bytes-append raw #" ")
      "invalid-public-key"
      binding)))
  (define tampered
    (string->bytes/utf-8
     (string-replace
      (bytes->string/utf-8 raw)
      "TRADE_SUCCESS" "TRADE_CLOSED")))
  (check-exn
   (code? 'alipay-query-signature-invalid)
   (lambda ()
     (verify-alipay-trade-query-response tampered public-key binding)))
  (define extra
    (bytes-append (subbytes raw 0 (sub1 (bytes-length raw)))
                  #",\"untrusted\":true}"))
  (check-exn
   (code? 'alipay-query-invalid)
   (lambda ()
     (verify-alipay-trade-query-response extra public-key binding)))
  (check-equal? (alipay-confirmed-order-trade-id queried)
                "202610301234567890"))

(test-case "OpenAPI request and notification signing use distinct fields"
  (define fields '(("sign_type" . "RSA2") ("app_id" . "app")
                   ("sign" . "ignored") ("empty" . "")))
  (check-equal? (alipay-request-signing-content fields)
                "app_id=app&sign_type=RSA2")
  (check-equal? (alipay-signing-content fields) "app_id=app&empty="))

(test-case "trade query request is signed for exactly this merchant order"
  (define params
    (make-alipay-trade-query-parameters
     binding rsa-private-key #:timestamp "2026-10-30 12:30:00"))
  (check-equal? (cdr (assoc "method" params)) "alipay.trade.query")
  (check-equal? (hash-ref
                 (string->jsexpr (cdr (assoc "biz_content" params)))
                 'out_trade_no)
                "order_test_001")
  (check-true
   (digest/verify
    (pk-key->public-only-key rsa-private-key)
    'sha256
    (string->bytes/utf-8 (test-request-content params))
    (base64-decode
     (string->bytes/utf-8 (cdr (assoc "sign" params))))
    #:pad 'pkcs1-v1.5)))


(test-case "HTTP form parser preserves UTF-8, plus, escape and duplicates"
  (check-equal? (parse-alipay-form #"a=hello+world&b=%E4%B8%AD&c=a%2Bb")
                (list (cons "a" "hello world")
                      (cons "b" "中")
                      (cons "c" "a+b")))
  (check-exn (code? 'alipay-duplicate-field)
             (lambda () (parse-alipay-form #"app_id=good&app_id=evil")))
  (for ([bad (list #"" #"noequals" #"a=1&" #"a=%FG"
                    #"a=%E4%B8" #"a=%")])
    (check-exn (code? 'alipay-form-invalid)
               (lambda () (parse-alipay-form bad))))
  (check-exn (code? 'alipay-form-invalid)
             (lambda () (parse-alipay-form (make-bytes 65537 97))))
  (check-exn (code? 'alipay-form-invalid)
             (lambda ()
               (parse-alipay-form
                (string->bytes/utf-8
                 (string-join (make-list 129 "a=1") "&"))))))

(test-case "server-priced gateway page-pay parameters have a valid RSA2 signature"
  (define private-key
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (generate-private-key (get-pk 'rsa) '((nbits 2048)))))
  (define params
    (make-alipay-page-pay-parameters
     binding private-key
     #:title "Taskly Pro lifetime"
     #:notify-url "https://example.test/payments/alipay/notify"
     #:return-url "https://example.test/orders/return"
     #:timestamp "2026-10-30 12:30:00"))
  (check-equal? (cdr (assoc "method" params)) "alipay.trade.page.pay")
  (define biz (string->jsexpr (cdr (assoc "biz_content" params))))
  (check-equal? (hash-ref biz 'total_amount) "12.34")
  (check-equal? (hash-ref biz 'out_trade_no) "order_test_001")
  (check-true
   (digest/verify
    (pk-key->public-only-key private-key) 'sha256
    (string->bytes/utf-8 (test-request-content params))
    (base64-decode
     (string->bytes/utf-8 (cdr (assoc "sign" params))))
    #:pad 'pkcs1-v1.5))
  (check-exn (code? 'alipay-checkout-invalid)
             (lambda ()
               (make-alipay-page-pay-parameters
                binding private-key #:title "test"
                #:notify-url "http://insecure.test"
                #:return-url "https://example.test/ok"
                #:timestamp "2026-10-30 12:30:00"))))

(test-case "HTTP Alipay callback journals exactly once and a retry is idempotent"
  (define temp-dir (make-temporary-file "commerce-alipay-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage
       (open-sqlite-commerce-storage (build-path temp-dir "commerce.sqlite")))
     (dynamic-wind
      void
      (lambda ()
        (storage-create-checkout-binding!
         storage
         (checkout-binding "order_test_001" "alipay"
                           "taskly" "taskly-pro-lifetime" "subject-1"
                           "CNY" 1234 2)
         #:created-at 1)
        (define query-count 0)
        (define endpoint
          (make-alipay-webhook-endpoint
           #:app-id "2026000000000000"
           #:seller-id "2088000000000000"
           #:alipay-public-key public-key
           #:query-order
           (lambda (binding)
             (check-equal? (alipay-binding-order-id binding) "order_test_001")
             (set! query-count (add1 query-count))
             (signed-query-response))
           #:storage storage))
        ;; The original notification contains base64 + / = and a payment
        ;; timestamp with spaces; a real HTTP form must preserve all of it.
        (define (escape-value v)
          ;; Escape literal + before encoding spaces to +, or gmt_payment
          ;; would decode to a plus and invalidate the RSA2 signature.
          (string-replace
           (string-replace
            (string-replace
             (string-replace
              (string-replace v "%" "%25") "+" "%2B")
             "/" "%2F")
            "=" "%3D")
           " " "+"))
        (define payload
          (string->bytes/utf-8
           (string-join
            (for/list ([pair (in-list signed-fields)])
              (string-append
               (car pair) "="
               (escape-value (cdr pair))))
            "&")))
        (define-values (first-status first-body)
          (handle-alipay-webhook-post endpoint payload))
        (check-equal? first-status 200)
        (check-equal? first-body #"success")
        (define-values (retry-status retry-body)
          (handle-alipay-webhook-post endpoint payload))
        (check-equal? retry-status 200)
        (check-equal? retry-body #"success")
        (check-equal? query-count 2)
        (check-true (journal-record?
                     (journal-ref storage "alipay" "notify_test_001")))
        (define-values (tampered-status tampered-body)
          (handle-alipay-webhook-post
           endpoint
           (bytes-append payload #"&app_id=forged")))
        (check-equal? tampered-status 401)
        (check-equal? tampered-body #"failure")
        (define offline
          (make-alipay-webhook-endpoint
           #:app-id "2026000000000000"
           #:seller-id "2088000000000000"
           #:alipay-public-key public-key
           #:query-order
           (lambda (_) (error 'query "network connection lost"))
           #:storage storage))
        (define-values (unavailable-status unavailable-body)
          (handle-alipay-webhook-post offline payload))
        (check-equal? unavailable-status 503)
        (check-equal? unavailable-body #"failure"))
      (lambda () (storage-close storage))))
   (lambda () (delete-directory/files temp-dir))))

(test-case "real query transport contract signs request and verifies response"
  (define called 0)
  (define client
    (make-alipay-query-client
     #:app-id "2026000000000000"
     #:merchant-private-key rsa-private-key
     #:alipay-public-key public-key
     #:environment 'sandbox
     #:clock (lambda () "2026-10-30 12:30:00")
     #:transport
     (lambda (endpoint body)
       (set! called (add1 called))
       (check-equal?
        endpoint "https://openapi-sandbox.dl.alipaydev.com/gateway.do")
       (define params (parse-alipay-form body))
       (check-equal? (cdr (assoc "method" params)) "alipay.trade.query")
       (check-true
        (digest/verify
         (pk-key->public-only-key rsa-private-key)
         'sha256
         (string->bytes/utf-8 (test-request-content params))
         (base64-decode
          (string->bytes/utf-8 (cdr (assoc "sign" params))))
         #:pad 'pkcs1-v1.5))
       (values 200 (signed-query-response)))))
  (check-equal?
   (fetch-alipay-trade-query-response client binding)
   (signed-query-response))
  (check-equal? called 1)
  (define offline
    (make-alipay-query-client
     #:app-id "2026000000000000"
     #:merchant-private-key rsa-private-key
     #:alipay-public-key public-key
     #:environment 'production
     #:clock (lambda () "2026-10-30 12:30:00")
     #:transport (lambda _ (error 'network "private transport detail"))))
  (check-exn (code? 'alipay-query-unavailable)
             (lambda ()
               (fetch-alipay-trade-query-response offline binding))))
