#lang racket/base

;; Alipay Vibe Pay Basic Collection (RSA2 public-key mode). No merchant API
;; credentials, HTTP client, or private keys are loaded by this module.
;; `return_url` is never payment evidence. A caller must actively query the
;; merchant order before supplying matching verified order facts.
(provide
 alipay-signing-content
 parse-alipay-form
 make-alipay-page-pay-parameters
 make-alipay-trade-query-parameters
 verify-alipay-trade-query-response
 verify-alipay-signed-api-response
 alipay-cny->fen
 (struct-out alipay-binding)
 alipay-confirmed-order?
 alipay-confirmed-order-app-id
 alipay-confirmed-order-seller-id
 alipay-confirmed-order-order-id
 alipay-confirmed-order-trade-id
 alipay-confirmed-order-status
 alipay-confirmed-order-amount
 alipay-notification?
 alipay-notification-fields
 alipay-notification-order-id
 alipay-notification-trade-id
 alipay-notification-status
 alipay-notification-amount
 verify-alipay-notification
 confirm-alipay-onetime-payment)

(require base64
         crypto
         json
         crypto/libcrypto
         crypto/pem
         racket/list
         racket/format
         racket/port
         racket/string
         (only-in "provider.rkt" make-verified-payment-event)
         "private/model.rkt")

(define (fail code message)
  (raise (exn:fail:commerce message (current-continuation-marks) code (hash))))

(define (nonblank? s)
  (and (string? s) (positive? (string-length s))
       (not (regexp-match? #px"[\r\n]" s))))
(define (valid-fields? fields)
  (and (list? fields)
       (andmap (lambda (p)
                 (and (pair? p) (string? (car p))
                      (nonblank? (car p)) (string? (cdr p))))
               fields)))
(define (field fields name)
  (define x (assoc name fields))
  (and x (cdr x)))
(define (nonblank-field fields name)
  (define x (field fields name))
  (unless (nonblank? x) (fail 'alipay-fields-invalid "missing Alipay field"))
  x)

;; Input is a decoded, one-value-per-field association list. HTTP boundary
;; must use a parser preserving duplicated keys; never collapse to a hash.
;; The original values MUST retain their decoded spelling (no trimming).
(define (checked-fields who fields)
  (unless (valid-fields? fields)
    (raise-argument-error who "(listof (cons/c string? string?))" fields))
  (define names (map car fields))
  (unless (= (length names) (length (remove-duplicates names)))
    (fail 'alipay-duplicate-field "duplicate Alipay notification field"))
  fields)

;; Preserve form member multiplicity and exact decoded values. A hash-based
;; web framework parser loses duplicate parameters before signature checking.
;; Both byte count and field count are bounded before doing cryptography.
(define (parse-alipay-form raw)
  (unless (bytes? raw)
    (raise-argument-error 'parse-alipay-form "bytes?" raw))
  (when (> (bytes-length raw) 65536)
    (fail 'alipay-form-invalid "Alipay form exceeds size limit"))
  (define (hex-digit b)
    (cond [(<= 48 b 57) (- b 48)]
          [(<= 65 b 70) (- b 55)]
          [(<= 97 b 102) (- b 87)]
          [else #f]))
  (define (decode part)
    (define output (open-output-bytes))
    (let loop ([i 0])
      (when (< i (bytes-length part))
        (define b (bytes-ref part i))
        (cond
          [(= b 37)
           (unless (< (+ i 2) (bytes-length part))
             (fail 'alipay-form-invalid "truncated form escape"))
           (let ([hi (hex-digit (bytes-ref part (add1 i)))]
                 [lo (hex-digit (bytes-ref part (+ i 2)))])
             (unless (and hi lo)
               (fail 'alipay-form-invalid "malformed form escape"))
             (write-byte (+ (* hi 16) lo) output)
             (loop (+ i 3)))]
          [else
           (write-byte (if (= b 43) 32 b) output)
           (loop (add1 i))])))
    (with-handlers ([exn:fail?
                     (lambda (_) (fail 'alipay-form-invalid
                                       "form field not valid UTF-8"))])
      (bytes->string/utf-8 (get-output-bytes output))))
  (when (= (bytes-length raw) 0)
    (fail 'alipay-form-invalid "empty form"))
  (define items (regexp-split #rx#"&" raw))
  (when (> (length items) 128)
    (fail 'alipay-form-invalid "too many form fields"))
  (define fields
    (for/list ([item (in-list items)])
      (define matches (regexp-match #rx#"^([^=]+)=(.*)$" item))
      (unless matches
        (fail 'alipay-form-invalid "malformed form field"))
      (cons (decode (cadr matches)) (decode (caddr matches)))))
  (checked-fields 'parse-alipay-form fields))

(define (alipay-signing-content fields)
  (checked-fields 'alipay-signing-content fields)
  (string-join
   (for/list ([p (in-list (sort fields string<? #:key car))]
              #:unless (member (car p) '("sign" "sign_type")))
     (string-append (car p) "=" (cdr p)))
   "&"))

(define (alipay-cny->fen str)
  (unless (and (string? str)
               (regexp-match? #px"^(?:0|[1-9][0-9]*)(?:\\.[0-9]{1,2})?$" str))
    (fail 'alipay-amount-invalid "invalid CNY decimal amount"))
  (define parts (string-split str "."))
  (define whole (string->number (car parts)))
  (define fraction (if (null? (cdr parts)) "" (cadr parts)))
  (+ (* 100 whole)
     (string->number (substring (string-append fraction "00") 0 2))))

;; Binding is created from durable Commerce checkout state, never from
;; buyer_id / email / notify metadata.
(struct alipay-binding (app-id seller-id order-id offer-id subject-id amount)
  #:transparent
  #:guard (lambda (app seller order offer subject amount who)
            (unless (and (nonblank? app) (nonblank? seller)
                         (nonblank? order) (stable-id? offer)
                         (nonblank? subject) (money? amount)
                         (equal? (money-currency amount) "CNY"))
              (raise-arguments-error who "invalid server-side Alipay binding"))
            (values app seller order offer subject amount)))

;; This value must be constructed by the caller ONLY from an authenticated
;; active alipay.trade.query result. It must not be built from browser data.
(struct alipay-confirmed-order (app-id seller-id order-id trade-id status amount))
(struct alipay-notification (fields order-id trade-id status amount))

(define (read-public pem)
  (with-handlers ([exn:fail?
                   (lambda (_) (fail 'alipay-public-key-invalid
                                     "invalid Alipay public key"))])
    (define entry
      (call-with-input-bytes (string->bytes/utf-8 pem)
        (lambda (in) (read-pem in #:only (list #"PUBLIC KEY")))))
    (unless entry (error 'read-public "missing key"))
    (datum->pk-key (cdr entry) 'SubjectPublicKeyInfo
                   (list libcrypto-factory))))

(define (verify-alipay-notification fields public-key-pem)
  (checked-fields 'verify-alipay-notification fields)
  ;; PEM armour contains line breaks; the single-line protocol-field
  ;; predicate is deliberately not suitable for a public key.
  (unless (and (string? public-key-pem)
               (positive? (string-length public-key-pem))
               (equal? (field fields "sign_type") "RSA2"))
    (fail 'alipay-signature-invalid "invalid Alipay RSA2 signature mode"))
  (define signature
    (with-handlers ([exn:fail?
                     (lambda (_) (fail 'alipay-signature-invalid
                                       "invalid Alipay RSA2 signature"))])
      (base64-decode
       (string->bytes/utf-8 (nonblank-field fields "sign")))))
  (define signed-content
    (string->bytes/utf-8 (alipay-signing-content fields)))
  (define valid?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (digest/verify (read-public public-key-pem) 'sha256
                     signed-content signature #:pad 'pkcs1-v1.5)))
  (unless valid?
    (fail 'alipay-signature-invalid "invalid Alipay RSA2 signature"))
  (define amount (alipay-cny->fen (nonblank-field fields "total_amount")))
  (alipay-notification
   fields
   (nonblank-field fields "out_trade_no")
   (nonblank-field fields "trade_no")
   (nonblank-field fields "trade_status")
   amount))

;; The gateway form is built server-side from the durable checkout binding.
;; The caller sends these signed parameters to its *approved* Alipay gateway.
;; This pure builder never makes a network request and does not store the key.
(define (make-alipay-page-pay-parameters binding private-key
                                         #:title title
                                         #:notify-url notify-url
                                         #:return-url return-url
                                         #:timestamp timestamp)
  (unless (alipay-binding? binding)
    (raise-argument-error 'make-alipay-page-pay-parameters
                          "alipay-binding?" binding))
  (unless (and (nonblank? title) (<= (string-length title) 256)
               (nonblank? timestamp)
               (regexp-match?
                #px"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"
                timestamp)
               (andmap (lambda (x)
                         (and (string? x) (string-prefix? x "https://")
                              (not (or (string-contains? x (string #\return))
                                       (string-contains? x (string #\newline))))))
                       (list notify-url return-url)))
    (fail 'alipay-checkout-invalid "invalid server-side checkout settings"))
  (define amount (money-minor-units (alipay-binding-amount binding)))
  (unless (> amount 0)
    (fail 'alipay-checkout-invalid "cannot charge zero CNY"))
  (define amount-text
    (format "~a.~a" (quotient amount 100)
            (~r (remainder amount 100) #:min-width 2 #:pad-string "0")))
  (define business
    (jsexpr->string
     (hasheq 'out_trade_no (alipay-binding-order-id binding)
             'total_amount amount-text
             'subject title
             'product_code "FAST_INSTANT_TRADE_PAY")))
  (define fields
    (list (cons "app_id" (alipay-binding-app-id binding))
          (cons "method" "alipay.trade.page.pay")
          (cons "format" "JSON")
          (cons "charset" "utf-8")
          (cons "sign_type" "RSA2")
          (cons "timestamp" timestamp)
          (cons "version" "1.0")
          (cons "notify_url" notify-url)
          (cons "return_url" return-url)
          (cons "biz_content" business)))
  (define signature
    (with-handlers ([exn:fail?
                     (lambda (_)
                       (fail 'alipay-checkout-signing-failed
                             "could not sign Alipay checkout request"))])
      (parameterize ([crypto-factories (list libcrypto-factory)])
        (digest/sign private-key 'sha256
                     (string->bytes/utf-8
                      (alipay-signing-content fields))
                     #:pad 'pkcs1-v1.5))))
  (cons (cons "sign"
              (bytes->string/utf-8 (base64-encode signature #:line #f)))
        fields))

;; A signed query request identifies the exact, durably bound merchant
;; order. The response is authenticated independently using the Alipay
;; PUBLIC key and the response-node's literal JSON bytes.
(define (make-alipay-trade-query-parameters binding private-key
                                           #:timestamp timestamp)
  (unless (alipay-binding? binding)
    (raise-argument-error 'make-alipay-trade-query-parameters
                          "alipay-binding?" binding))
  (unless (and (string? timestamp)
               (regexp-match?
                #px"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"
                timestamp))
    (fail 'alipay-query-invalid "invalid Alipay query timestamp"))
  (define fields
    (list
     (cons "app_id" (alipay-binding-app-id binding))
     (cons "method" "alipay.trade.query")
     (cons "format" "JSON")
     (cons "charset" "utf-8")
     (cons "sign_type" "RSA2")
     (cons "timestamp" timestamp)
     (cons "version" "1.0")
     (cons "biz_content"
           (jsexpr->string
            (hasheq 'out_trade_no (alipay-binding-order-id binding))))))
  (define signature
    (with-handlers ([exn:fail?
                     (lambda (_)
                       (fail 'alipay-query-signing-failed
                             "Alipay query request signature unavailable"))])
      (parameterize ([crypto-factories (list libcrypto-factory)])
        (digest/sign private-key 'sha256
                     (string->bytes/utf-8
                      (alipay-signing-content fields))
                     #:pad 'pkcs1-v1.5))))
  (cons (cons "sign"
              (bytes->string/utf-8 (base64-encode signature #:line #f)))
        fields))

;; Scan the exact returned JSON value; JSON->hash->JSON reserialization
;; changes key ordering, whitespace, escaped slashes and the signed bytes.
;; Accept precisely { "alipay_trade_query_response": {...}, "sign": "..." }.
;; Certificate-mode response metadata is NOT admitted in this public-key
;; mode, so it must not be silently interpreted as public-key mode.
(define (query-response-signed-fragment raw #:node-name [node-name "alipay_trade_query_response"])
  (unless (bytes? raw)
    (raise-argument-error 'verify-alipay-trade-query-response "bytes?" raw))
  (when (> (bytes-length raw) 65536)
    (fail 'alipay-query-invalid "Alipay query response too large"))
  (define txt
    (with-handlers ([exn:fail?
                     (lambda (_) (fail 'alipay-query-invalid
                                       "Alipay query response is not UTF-8"))])
      (bytes->string/utf-8 raw)))
  (unless (member node-name
                  '("alipay_trade_query_response"
                    "alipay_trade_refund_response"
                    "alipay_trade_fastpay_refund_query_response"))
    (fail 'alipay-query-invalid "unsupported Alipay signed response node"))
  (define prefix
    (regexp-match-positions
     (pregexp
      (string-append "^[ \t\r\n]*\\{[ \t\r\n]*\""
                     (regexp-quote node-name)
                     "\"[ \t\r\n]*:"))
     txt))
  (unless prefix
    (fail 'alipay-query-invalid "missing signed Alipay query response"))
  (define length* (string-length txt))
  (define (whitespace? ch)
    (or (char=? ch #\space) (char=? ch #\tab)
        (char=? ch #\return) (char=? ch #\newline)))
  (define begin*
    (let skip ([i (cdar prefix)])
      (if (and (< i length*) (whitespace? (string-ref txt i)))
          (skip (add1 i)) i)))
  (unless (and (< begin* length*) (char=? (string-ref txt begin*) #\{))
    (fail 'alipay-query-invalid "query response must be an object"))
  (define end*
    (let loop ([i begin*] [level 0] [quoted? #f] [escaped? #f])
      (when (>= i length*)
        (fail 'alipay-query-invalid "unterminated Alipay query response"))
      (define ch (string-ref txt i))
      (cond
        [quoted?
         (cond
           [escaped? (loop (add1 i) level #t #f)]
           [(char=? ch #\\) (loop (add1 i) level #t #t)]
           [(char=? ch #\") (loop (add1 i) level #f #f)]
           [else (loop (add1 i) level #t #f)])]
        [(char=? ch #\") (loop (add1 i) level #t #f)]
        [(char=? ch #\{) (loop (add1 i) (add1 level) #f #f)]
        [(char=? ch #\})
         (if (= level 1) (add1 i)
             (loop (add1 i) (sub1 level) #f #f))]
        [else (loop (add1 i) level #f #f)])))
  (define tail (substring txt end*))
  (define matches
    (regexp-match
     #px"^[ \t\r\n]*,[ \t\r\n]*\"sign\"[ \t\r\n]*:[ \t\r\n]*\"([A-Za-z0-9+/]+={0,2})\"[ \t\r\n]*\\}[ \t\r\n]*$"
     tail))
  (unless matches
    (fail 'alipay-query-invalid "unexpected Alipay response envelope"))
  (values (substring txt begin* end*) (cadr matches)))

(define (verify-alipay-signed-api-response raw public-key-pem node-name)
  (define-values (content sign)
    (query-response-signed-fragment raw #:node-name node-name))
  (define authentic?
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (digest/verify
       (read-public public-key-pem)
       'sha256
       (string->bytes/utf-8 content)
       (base64-decode (string->bytes/utf-8 sign))
       #:pad 'pkcs1-v1.5)))
  (unless authentic?
    (fail 'alipay-query-signature-invalid
          "invalid signed Alipay API response"))
  (define decoded
    (with-handlers ([exn:fail?
                     (lambda (_) (fail 'alipay-query-invalid
                                       "invalid signed Alipay API JSON"))])
      (string->jsexpr content)))
  (unless (hash? decoded)
    (fail 'alipay-query-invalid "Alipay signed API result is not an object"))
  decoded)

(define (verify-alipay-trade-query-response raw public-key-pem binding)
  (unless (alipay-binding? binding)
    (raise-argument-error 'verify-alipay-trade-query-response
                          "alipay-binding?" binding))
  (define decoded
    (verify-alipay-signed-api-response
     raw public-key-pem "alipay_trade_query_response"))
  (define (required name)
    (define value (hash-ref decoded name #f))
    (unless (nonblank? value)
      (fail 'alipay-query-invalid "missing Alipay query result field"))
    value)
  (unless (equal? (required 'code) "10000")
    (fail 'alipay-query-rejected "Alipay trade query was rejected"))
  (define order (required 'out_trade_no))
  (define trade (required 'trade_no))
  (define status (required 'trade_status))
  (define total (alipay-cny->fen (required 'total_amount)))
  (unless (and (equal? order (alipay-binding-order-id binding))
               (= total (money-minor-units (alipay-binding-amount binding)))
               (or (not (hash-has-key? decoded 'seller_id))
                   (equal? (required 'seller_id)
                           (alipay-binding-seller-id binding)))
               (or (not (hash-has-key? decoded 'app_id))
                   (equal? (required 'app_id)
                           (alipay-binding-app-id binding))))
    (fail 'alipay-order-mismatch
          "signed Alipay query result differs from merchant checkout"))
  ;; The merchant application identity comes from the *request binding*;
  ;; alipay.trade.query does not necessarily echo app_id in its response.
  (alipay-confirmed-order
   (alipay-binding-app-id binding)
   (alipay-binding-seller-id binding)
   order trade status total))

;; The active query must be checked against the *same* persisted binding,
;; not trusted from an arbitrary service callback. This first slice handles
;; only full one-time payments; partial refund events need a separate model.
(define (confirm-alipay-onetime-payment notice binding query
                                        #:payload-digest payload-digest
                                        #:occurred-at occurred-at)
  (unless (and (alipay-notification? notice)
               (alipay-binding? binding)
               (alipay-confirmed-order? query))
    (raise-arguments-error 'confirm-alipay-onetime-payment
                           "expected signed notification, binding and active query"))
  (define f (alipay-notification-fields notice))
  (unless (and
           (equal? (alipay-notification-status notice) "TRADE_SUCCESS")
           (equal? (alipay-confirmed-order-status query) "TRADE_SUCCESS")
           (equal? (nonblank-field f "app_id") (alipay-binding-app-id binding))
           (equal? (nonblank-field f "seller_id") (alipay-binding-seller-id binding))
           (equal? (alipay-notification-order-id notice) (alipay-binding-order-id binding))
           (equal? (alipay-notification-trade-id notice) (alipay-confirmed-order-trade-id query))
           (= (alipay-notification-amount notice)
              (money-minor-units (alipay-binding-amount binding)))
           (equal? (alipay-confirmed-order-app-id query) (alipay-binding-app-id binding))
           (equal? (alipay-confirmed-order-seller-id query) (alipay-binding-seller-id binding))
           (equal? (alipay-confirmed-order-order-id query) (alipay-binding-order-id binding))
           (= (alipay-confirmed-order-amount query)
              (money-minor-units (alipay-binding-amount binding))))
    (fail 'alipay-order-mismatch
          "Alipay notification and active order do not match checkout binding"))
  (make-verified-payment-event
   "alipay" (nonblank-field f "notify_id") payload-digest
   'payment-succeeded (alipay-binding-order-id binding)
   (alipay-binding-offer-id binding) (alipay-binding-subject-id binding)
   (alipay-binding-amount binding) occurred-at))
