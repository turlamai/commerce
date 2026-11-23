#lang racket/base
(require crypto crypto/pem crypto/libcrypto db json permit/json permit/issuer permit/crypto
         racket/file racket/path racket/port racket/string
         "../nowpay-direct.rkt" "issuer.rkt" "../private/model.rkt" "../private/bounded-stream.rkt")
(provide run-nowpay-direct-cli!)

(define (refuse) (error 'nowpay-direct "private service configuration unavailable"))
(define (read-config path)
  (define value (read-json-bytes/strict 'nowpay-direct (file->bytes path)))
  (unless (and (hash? value) (equal? (hash-ref value 'version #f) 1)
               (equal? (hash-ref value 'environment #f) "production")) (refuse))
  value)
(define (config-path cfg field)
  (define p (hash-ref cfg field))
  (unless (and (string? p) (absolute-path? p) (file-exists? p)) (refuse)) p)
(define (private-rsa path)
  (define entry (call-with-input-file path (lambda (in) (read-pem in #:only '(#"PRIVATE KEY" #"RSA PRIVATE KEY")))))
  (unless entry (refuse))
  (datum->pk-key (cdr entry) (if (bytes=? (car entry) #"PRIVATE KEY") 'OneAsymmetricKey 'RSAPrivateKey) (list libcrypto-factory)))
(define (client-from cfg)
  (make-nowpay-direct-client #:app-id (hash-ref cfg 'app_id)
   #:merchant-private-key (private-rsa (config-path cfg 'merchant_private_key_path))
   #:alipay-public-key (file->string (config-path cfg 'alipay_public_key_path))
   #:out-product-id (hash-ref cfg 'out_product_id) #:price-minor (hash-ref cfg 'price_minor)
   #:sku-id (hash-ref cfg 'sku_id #f) #:callback-url (hash-ref cfg 'callback_url)))
(define (run-nowpay-direct-cli! config-file command)
  (with-handlers ([exn:fail?
    (lambda (e)
      ;; No config values, raw provider errors, keys or input frames reach stdout.
      (write-json (hasheq 'status "unavailable" 'code
        (if (exn:fail:commerce? e) (symbol->string (exn:fail:commerce-code e)) "nowpay-direct-unavailable")))
      (newline) 1)])
    (define cfg (read-config config-file))
    (define client (client-from cfg))
    (cond
      [(equal? command "charge")
       (define result (nowpay-direct-charge-query client))
       (write-json (hasheq 'capability_status (nowpay-charge-status result)
                    'purchasable (nowpay-charge-purchasable? result)
                    'sku_id (or (nowpay-charge-sku-id result) 'null)
                    'price_minor (hash-ref cfg 'price_minor) 'duration_period "MONTH"))
       (newline) 0]
      [(equal? command "serve")
       ;; Production signing must never silently fall back to pure Ed25519.
       (current-ed25519-backend 'native)
       (define raw (read-bounded-stream (current-input-port) 16384 5))
       (unless raw (refuse))
       (define request (read-json-bytes/strict 'nowpay-direct raw))
       (define state (hash-ref cfg 'state_path))
       (unless (and (string? state) (absolute-path? state) (directory-exists? (path-only state))) (refuse))
       (unless (zero? (bitwise-and #o077 (file-or-directory-permissions (path-only state) 'bits))) (refuse))
       (define database (sqlite3-connect #:database state #:mode 'create))
       (file-or-directory-permissions state #o600)
       (dynamic-wind void
        (lambda ()
          (define issuer (make-nowpay-direct-issuer #:client client #:database database
           #:issuer (hash-ref cfg 'issuer) #:service-id (hash-ref cfg 'service_id)
           #:product-id (hash-ref cfg 'product_id) #:edition (hash-ref cfg 'edition)
           #:private-key (read-ed25519-private-key (config-path cfg 'permit_private_key_path))
           #:key-id (hash-ref cfg 'permit_key_id)
           #:trust-store (read-trust-store (config-path cfg 'permit_trust_store_path))
           #:purchasing-enabled? (hash-ref cfg 'purchasing_enabled #f)
           #:purchase-buyer-allowlist (hash-ref cfg 'purchase_buyer_allowlist #f)))
          (write-json (authorize-nowpay-direct issuer request)) (newline) (flush-output) 0)
        (lambda () (disconnect database)))]
      [else (refuse)])))
