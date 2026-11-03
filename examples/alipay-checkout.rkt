#lang racket/base

;; Trusted OPERATOR example: create a durable, server-priced checkout binding
;; before generating a signed Alipay page-pay form. No browser/user-submitted
;; price or subject identity is accepted by a public HTTP endpoint.
(require crypto
         crypto/libcrypto
         crypto/pem
         racket/cmdline
         racket/file
         racket/port
         racket/string
         commerce
         commerce/alipay
         commerce/admission
         commerce/private/alipay-time
         commerce/storage
         commerce/storage/sqlite)

(define (required name)
  (define value (getenv name))
  (unless (and value (not (string=? value "")))
    (error 'alipay-checkout "missing required environment setting: ~a" name))
  value)

(define (china-timestamp)
  ;; The checkout example must use the same UTC+08:00 contract as the API
  ;; client and journal, even when the operator's host is in another zone.
  (epoch-seconds->gmt8-timestamp (current-seconds)))

(define (merchant-key path)
  (define entry
    (call-with-input-string
     (string-replace (file->string path) "\r\n" "\n")
     (lambda (in)
       (read-pem in #:only (list #"PRIVATE KEY" #"RSA PRIVATE KEY")))))
  (unless (pair? entry)
    (error 'alipay-checkout "merchant key PEM is invalid"))
  (define format
    (if (bytes=? (car entry) #"PRIVATE KEY")
        'OneAsymmetricKey 'RSAPrivateKey))
  (define key (datum->pk-key (cdr entry) format (list libcrypto-factory)))
  (unless (private-key? key)
    (error 'alipay-checkout "merchant signing key is not private"))
  key)

(define (escape-html value)
  (for/fold ([s value])
            ([pair (in-list
                    (list (cons "&" "&amp;")
                          (cons "<" "&lt;")
                          (cons ">" "&gt;")
                          (cons "\"" "&quot;")
                          (cons "'" "&#39;")))])
    (string-replace s (car pair) (cdr pair))))

(module+ main
  (command-line
   #:program "alipay-checkout"
   #:args (product-id offer-id subject-id amount-fen title)
   (define amount (string->number amount-fen))
   (unless (and (exact-positive-integer? amount)
                (<= amount 99999999999))
     (error 'alipay-checkout "operator price must be positive integer CNY fen"))
   (define env (required "ALIPAY_ENV"))
   (define gateway
     (cond
       [(equal? env "sandbox")
        "https://openapi-sandbox.dl.alipaydev.com/gateway.do"]
       [(equal? env "production")
        "https://openapi.alipay.com/gateway.do"]
       [else (error 'alipay-checkout "ALIPAY_ENV must be sandbox or production")]))
   ;; ADR-0019 gate: refuse before minting a checkout binding, loading the
   ;; merchant private key, or presenting a browser-pay form. This private
   ;; record is reviewed and provisioned by the operator, not the buyer.
   (define app-id (required "ALIPAY_APP_ID"))
   (define seller-id (required "ALIPAY_SELLER_ID"))
   (authorize-provider-checkout!
    (read-provider-admission (required "COMMERCE_PROVIDER_ADMISSION_PATH"))
    #:provider "alipay" #:environment env
    #:merchant-app-id app-id #:seller-id seller-id
    #:product-id product-id #:offer-id offer-id
    #:payment-method "alipay" #:transaction-type "one-time"
    #:amount (money "CNY" amount))
   (define order-id
     (string-append "ali" (bytes->hex-string (crypto-random-bytes 16))))
   (define binding
     (alipay-binding
      app-id
      seller-id
      order-id offer-id subject-id (money "CNY" amount)))
   (define storage
     (open-sqlite-commerce-storage (required "COMMERCE_DATABASE_PATH")))
   (dynamic-wind
    void
    (lambda ()
      (storage-create-checkout-binding!
       storage
       (checkout-binding order-id "alipay" product-id offer-id subject-id
                         "CNY" amount 2)
       #:created-at (current-seconds)))
    (lambda () (storage-close storage)))
   (define fields
     (make-alipay-page-pay-parameters
      binding
      (merchant-key (required "ALIPAY_PRIVATE_KEY_PATH"))
      #:title title
      #:notify-url (required "ALIPAY_NOTIFY_URL")
      #:return-url (required "ALIPAY_RETURN_URL")
      #:timestamp (china-timestamp)))
   ;; The output contains a signed REQUEST, not a private key. Keep the
   ;; order ID as the customer recovery correlation handle.
   (printf "<!doctype html><html><head><meta charset=\"utf-8\"><title>Checkout</title></head><body>\n")
   (printf "<form action=\"~a\" method=\"POST\">\n" (escape-html gateway))
   (for ([f (in-list fields)])
     (printf "<input type=\"hidden\" name=\"~a\" value=\"~a\">\n"
             (escape-html (car f)) (escape-html (cdr f))))
   (printf "<button type=\"submit\">Pay with Alipay</button></form></body></html>\n")))
