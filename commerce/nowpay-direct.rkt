#lang racket/base

;; Provider-specific live access decisions. These are NOT payment events and
;; cannot be reconstructed from caller-supplied ALLOW JSON. See ADR-0027.
(require base64 crypto json racket/list racket/string permit/json
         "alipay.rkt" (submod "alipay/client.rkt" internal)
         "private/alipay-time.rkt" "private/model.rkt")
(provide make-nowpay-direct-client nowpay-direct-client?
         nowpay-direct-charge-query nowpay-direct-purchase-consult
         nowpay-charge? nowpay-charge-status nowpay-charge-sku-id nowpay-charge-purchasable?
         nowpay-access? nowpay-access-decision nowpay-access-buyer-id
         nowpay-access-product-id nowpay-access-valid-from nowpay-access-valid-until
         nowpay-access-purchase-url nowpay-access-qr-code)

(struct nowpay-direct-client (app-id private-key public-key product price sku callback transport clock))
(struct nowpay-charge (status sku-id purchasable?))
(struct nowpay-access (decision buyer-id product-id valid-from valid-until purchase-url qr-code raw))
(module+ internal (provide nowpay-access-raw))
(define gateway "https://openapi.alipay.com/gateway.do")
(define statuses '("NOT_CONFIGURED" "CONFIGURING" "PENDING" "ACTION_REQUIRED" "ENABLED" "DISABLED" "TERMINATED"))
(define (refuse code)
  (raise (exn:fail:commerce "NowPay Direct request refused"
                          (current-continuation-marks) code (hash))))
(define (id? value [limit 128])
  (and (string? value) (<= 1 (string-length value) limit)
       (not (regexp-match? #px"[[:cntrl:][:space:]]" value))))
(define (make-nowpay-direct-client #:app-id app #:merchant-private-key key
         #:alipay-public-key public #:out-product-id product #:price-minor price
         #:sku-id [sku #f] #:callback-url callback
         #:transport [transport default-transport] #:clock [clock current-seconds])
  (unless (and (id? app 32) (private-key? key) (string? public) (positive? (string-length public))
               (id? product) (exact-positive-integer? price) (or (not sku) (id? sku 32))
               (id? callback) (regexp-match? #rx"^https://[^/]+/" callback)
               (procedure? transport) (procedure? clock))
    (refuse 'nowpay-direct-configuration-invalid))
  (nowpay-direct-client app key public product price sku callback transport clock))

(define (request client operation biz)
  (unless (nowpay-direct-client? client) (refuse 'nowpay-direct-configuration-invalid))
  (with-handlers ([exn:fail:commerce?
                  (lambda (e)
                    (if (regexp-match? #rx"^nowpay-direct" (symbol->string (exn:fail:commerce-code e)))
                        (raise e) (refuse 'nowpay-direct-response-invalid)))]
                 [exn:fail? (lambda (_) (refuse 'nowpay-direct-response-invalid))])
    (define now ((nowpay-direct-client-clock client)))
    (define method (string-append "alipay.aipay.nowpaydirect." operation))
    (define params
      (list (cons "app_id" (nowpay-direct-client-app-id client)) (cons "method" method)
            (cons "format" "JSON") (cons "charset" "utf-8") (cons "sign_type" "RSA2")
            (cons "timestamp" (epoch-seconds->gmt8-timestamp now))
            (cons "version" "1.0") (cons "biz_content" (jsexpr->string biz))))
    (define signature
      (digest/sign (nowpay-direct-client-private-key client) 'sha256
                   (string->bytes/utf-8 (alipay-request-signing-content params)) #:pad 'pkcs1-v1.5))
    (define fields (cons (cons "sign" (bytes->string/utf-8 (base64-encode signature #:line #f))) params))
    (define-values (status raw)
      (with-handlers ([exn:fail? (lambda (_) (refuse 'nowpay-direct-unavailable))])
        ((nowpay-direct-client-transport client) gateway (form-encode fields))))
    (unless (and (exact-integer? status) (= status 200) (bytes? raw) (<= (bytes-length raw) 65536))
      (refuse 'nowpay-direct-unavailable))
    (define node (string-append (string-replace method "." "_") "_response"))
    (verify-alipay-signed-api-response raw (nowpay-direct-client-public-key client) node)
    ;; The existing verifier authenticates literal JSON bytes. Strict parsing
    ;; afterwards also rejects duplicate members, including nested SKU fields.
    (define envelope (read-json-bytes/strict 'nowpay-direct raw))
    (define result (hash-ref envelope (string->symbol node)))
    (unless (equal? (hash-ref result 'code #f) "10000") (refuse 'nowpay-direct-provider-rejected))
    (unless (member (hash-ref result 'capability_status #f) statuses) (refuse 'nowpay-direct-response-invalid))
    (values result (bytes->immutable-bytes raw))))

(define (matching-sku client body)
  (define options (hash-ref body 'charging_options #f))
  (unless (and (list? options) (<= (length options) 32)) (refuse 'nowpay-direct-response-invalid))
  (define matching
    (for/list ([option (in-list options)]
               #:when
               (begin
                 (unless (and (hash? option) (id? (hash-ref option 'sku_id #f) 32)
                              (string? (hash-ref option 'display_name #f))
                              (string? (hash-ref option 'price #f)))
                   (refuse 'nowpay-direct-response-invalid))
                 (and (equal? (hash-ref option 'duration_period #f) "MONTH")
                      (= (alipay-cny->fen (hash-ref option 'price)) (nowpay-direct-client-price client))
                      (or (not (nowpay-direct-client-sku client))
                          (equal? (hash-ref option 'sku_id) (nowpay-direct-client-sku client))))))
      (hash-ref option 'sku_id)))
  (and (= (length options) 1) (= (length matching) 1) (car matching)))

(define (safe-matching-sku client body)
  (with-handlers ([exn:fail? (lambda (_) (refuse 'nowpay-direct-policy-mismatch))])
    (matching-sku client body)))

(define (nowpay-direct-charge-query client)
  (define-values (body _) (request client "charge.query"
    (hasheq 'out_product_id (nowpay-direct-client-product client))))
  (define enabled? (equal? (hash-ref body 'capability_status) "ENABLED"))
  (define sku (safe-matching-sku client body))
  (when (and enabled? (or (not sku) (not (equal? (hash-ref body 'billing_mode #f) "ONE_TIME_DURATION"))))
    (refuse 'nowpay-direct-policy-mismatch))
  (nowpay-charge (hash-ref body 'capability_status) sku (and enabled? sku #t)))

(define (allowed-url value qr?)
  (and (id? value 512)
       (regexp-match? (if qr? #rx"^https://mobilecodec[.]alipay[.]com/"
                         #rx"^(alipays://platformapi/startapp[?]|https://([a-zA-Z0-9-]+[.])*alipay[.]com/)") value)
       value))

(define (nowpay-direct-purchase-consult client buyer)
  (unless (id? buyer) (refuse 'nowpay-direct-buyer-invalid))
  (define-values (body raw) (request client "purchase.consult"
    (hasheq 'out_product_id (nowpay-direct-client-product client)
            'external_buyer_id buyer 'callback_url (nowpay-direct-client-callback client))))
  (define decision (hash-ref body 'decision #f))
  (unless (member decision '("ALLOW" "PURCHASE_REQUIRED" "DENY")) (refuse 'nowpay-direct-response-invalid))
  (define from #f) (define until #f) (define url #f) (define qr #f)
  (cond
    [(equal? decision "ALLOW")
     (with-handlers ([exn:fail? (lambda (_) (refuse 'nowpay-direct-period-invalid))])
       (set! from (gmt8-wall-time->epoch (hash-ref body 'valid_from)))
       (set! until (gmt8-wall-time->epoch (hash-ref body 'valid_until)))
       (unless (<= from ((nowpay-direct-client-clock client)) (sub1 until)) (refuse 'nowpay-direct-period-invalid)))]
    [(and (equal? decision "PURCHASE_REQUIRED") (equal? (hash-ref body 'capability_status) "ENABLED"))
     (unless (safe-matching-sku client body) (refuse 'nowpay-direct-policy-mismatch))
     (set! url (allowed-url (hash-ref body 'purchase_url #f) #f))
     (set! qr (allowed-url (hash-ref body 'purchase_qr_code #f) #t))
     (unless (or url qr) (refuse 'nowpay-direct-purchase-link-invalid))])
  (nowpay-access decision buyer (nowpay-direct-client-product client) from until url qr raw))
