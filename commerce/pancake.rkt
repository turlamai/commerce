#lang racket/base

(provide
 pancake-order-facts?
 pancake-order-facts-order-id
 pancake-order-facts-status
 pancake-order-facts-test-mode
 pancake-order-facts-payment-id
 pancake-order-facts-payment-status
 pancake-order-facts-currency
 pancake-order-facts-minor-units
 read-pancake-onetime-order
 pancake-webhook-keyring
 pancake-webhook-keyring?
 default-pancake-webhook-keyring
 pancake-webhook?
 pancake-webhook-environment
 pancake-webhook-id
 pancake-webhook-timestamp
 pancake-webhook-event-type
 pancake-webhook-event-id
 pancake-webhook-store-id
 pancake-webhook-store-name
 pancake-webhook-data
 pancake-webhook-raw-body
 pancake-webhook-payload-digest
 pancake-webhook-signature-timestamp-ms
 verify-pancake-webhook
 verify-pancake-webhook-signature
 pancake-api-endpoint
 (struct-out pancake-order-binding)
 pancake-merchant-client?
 make-pancake-merchant-client
 verify-pancake-onetime-order)

(require base64
         crypto
         crypto/libcrypto
         crypto/pem
         json
         net/http-easy
         racket/date
         racket/list
         racket/match
         racket/port
         racket/string
         (only-in "provider.rkt" make-verified-payment-event)
         "private/model.rkt")

(define default-past-tolerance-ms (* 45 60 1000))
(define default-future-tolerance-ms (* 60 1000))

;; These environment-specific verification keys mirror Pancake's official Go
;; SDK v0.17.0 (2026-10-10). Keeping them in a keyring makes the trust boundary
;; explicit and gives callers a controlled override for provider key rotation.
(define builtin-test-public-key
  #<<PEM
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxnmRY6yMMA3lVqmAU6ZG
b1sjL/+r/z6E+ZjkXaDAKiqOhk9rpazni0bNsGXwmftTPk9jy2wn+j6JHODD/WH/
SCnSfvKkLIjy4Hk7BuCgB174C0ydan7J+KgXLkOwgCAxxB68t2tezldwo74ZpXgn
F49opzMvQ9prEwIAWOE+kV9iK6gx/AckSMtHIHpUesoPDkldpmFHlB2qpf1vsFTZ
5kD6DmGl+2GIVK01aChy2lk8pLv0yUMu18v44sLkO5M44TkGPJD9qG09wrvVG2wp
OTVCn1n5pP8P+HRLcgzbUB3OlZVfdFurn6EZwtyL4ZD9kdkQ4EZE/9inKcp3c1h4
xwIDAQAB
-----END PUBLIC KEY-----
PEM
  )

(define builtin-production-public-key
  #<<PEM
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAz+xApdTIb4ua+DgZKQ54
iBsD82ybyhGCLRETONW4Jgbb3A8DUM1LqBk6r/CmTOCHqLalTQHNigvP3R5zkDNX
iRJz6gA4MJ/+8K0+mnEE2RISQzN+Qu65TNd6svb+INm/kMaftY4uIXr6y6kchtTJ
dwnQhcKdAL2v7h7IFnkVelQsKxDdb2PqX8xX/qwd01iXvMcpCCaXovUwZsxH2QN5
ZKBTseJivbhUeyJCco4fdUyxOMHe2ybCVhyvim2uxAl1nkvL5L8RCWMCAV55LLo0
9OhmLahz/DYNu13YLVP6dvIT09ZFBYU6Owj1NxdinTynlJCFS9VYwBgmftosSE1U
dwIDAQAB
-----END PUBLIC KEY-----
PEM
  )

(define (non-empty-string? value)
  (and (string? value) (not (string=? (string-trim value) ""))))

(define (same-pem-text? left right)
  (string=? (regexp-replace* #px"\\s+" left "")
            (regexp-replace* #px"\\s+" right "")))

(struct pancake-webhook-keyring (test-key production-key)
  #:guard
  (lambda (test-key production-key who)
    (unless (non-empty-string? test-key)
      (raise-arguments-error
       who "test public key must be a non-empty string"))
    (unless (non-empty-string? production-key)
      (raise-arguments-error
       who "production public key must be a non-empty string"))
    (when (same-pem-text? test-key production-key)
      (raise-arguments-error
       who "test and production public keys must be different"))
    (values test-key production-key)))

(define default-pancake-webhook-keyring
  (pancake-webhook-keyring
   builtin-test-public-key
   builtin-production-public-key))

;; The verified value deliberately remains provider-native. A later adapter
;; slice may query the active order and construct a canonical payment-event.
(struct pancake-webhook
  (environment id timestamp event-type event-id store-id store-name data
               raw-body payload-digest signature-timestamp-ms))

(define (raise-commerce code message [data (hash)])
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (environment? value)
  (memq value '(test production)))

(define (parse-signature-header header)
  (unless (string? header)
    (raise-arguments-error
     'verify-pancake-webhook
     "signature-header must be a string"))
  (when (string=? header "")
    (raise-commerce
     'pancake-signature-header-missing
     "missing X-Waffo-Signature header"))
  (define fields
    (for/fold ([parsed (hash)]) ([part (in-list (string-split header ","))])
      (match (regexp-match #px"^([^=]+)=(.*)$" part)
        [(list _ raw-name raw-value)
         (define name (string-trim raw-name))
         (define value (string-trim raw-value))
         (cond
           [(member name '("t" "v1"))
            (when (or (string=? value "") (hash-has-key? parsed name))
              (raise-commerce
               'pancake-signature-header-malformed
               "malformed X-Waffo-Signature header"))
            (hash-set parsed name value)]
           [else parsed])]
        [_ parsed])))
  (unless (and (hash-has-key? fields "t")
               (hash-has-key? fields "v1"))
    (raise-commerce
     'pancake-signature-header-malformed
     "malformed X-Waffo-Signature header"))
  (values (hash-ref fields "t") (hash-ref fields "v1")))

(define (parse-timestamp value)
  (unless (regexp-match? #px"^(?:0|[1-9][0-9]*)$" value)
    (raise-commerce
     'pancake-timestamp-invalid
     "invalid timestamp in X-Waffo-Signature header"))
  (define timestamp (string->number value))
  (unless (exact-nonnegative-integer? timestamp)
    (raise-commerce
     'pancake-timestamp-invalid
     "invalid timestamp in X-Waffo-Signature header"))
  timestamp)

(define (check-timestamp-window timestamp now-ms past-tolerance-ms
                                future-tolerance-ms)
  (define age (- now-ms timestamp))
  (when (or (> age past-tolerance-ms)
            (< age (- future-tolerance-ms)))
    (raise-commerce
     'pancake-timestamp-outside-tolerance
     "webhook timestamp is outside the accepted tolerance window"
     (hash 'past-tolerance-ms past-tolerance-ms
           'future-tolerance-ms future-tolerance-ms))))

(define (public-key-for keyring environment)
  (case environment
    [(test) (pancake-webhook-keyring-test-key keyring)]
    [(production) (pancake-webhook-keyring-production-key keyring)]))

(define (parse-public-key pem environment)
  (with-handlers ([exn:fail?
                   (lambda (_failure)
                     (raise-commerce
                      'pancake-public-key-invalid
                      "Pancake webhook public key is invalid"
                      (hash 'environment environment)))])
    (define entry
      (call-with-input-bytes
       (string->bytes/utf-8 pem)
       (lambda (in)
         (read-pem in #:only (list #"PUBLIC KEY")))))
    (unless entry
      (error 'parse-public-key "no PUBLIC KEY entry"))
    (datum->pk-key
     (cdr entry)
     'SubjectPublicKeyInfo
     (list libcrypto-factory))))

(define (decode-signature encoded environment)
  (with-handlers ([exn:fail?
                   (lambda (_failure)
                     (raise-commerce
                      'pancake-signature-invalid
                      "invalid Pancake webhook signature"
                      (hash 'environment environment)))])
    (base64-decode (string->bytes/utf-8 encoded))))

(define (verify-signature public-key signed-bytes signature environment)
  (define valid?
    (with-handlers ([exn:fail? (lambda (_failure) #f)])
      (digest/verify
       public-key 'sha256 signed-bytes signature #:pad 'pkcs1-v1.5)))
  (unless valid?
    (raise-commerce
     'pancake-signature-invalid
     "invalid Pancake webhook signature"
     (hash 'environment environment))))

(define (payload-digest raw-body)
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (bytes->hex-string (digest 'sha256 raw-body))))

(define required-string-fields
  '(id timestamp eventType eventId storeId storeName))

(define (duplicate-top-level-key raw-body)
  ;; Racket's JSON reader intentionally keeps the last value of a duplicate
  ;; object key. Inspect the authenticated representation first so security-
  ;; critical envelope fields cannot be interpreted differently elsewhere.
  (define stack '())
  (define in-string? #f)
  (define escaped? #f)
  (define key-start #f)
  (define expect-key? #f)
  (define seen (hash))
  (define duplicate #f)
  (for ([index (in-range (bytes-length raw-body))]
        #:break duplicate)
    (define byte (bytes-ref raw-body index))
    (cond
      [in-string?
       (cond
         [escaped? (set! escaped? #f)]
         [(= byte 92) (set! escaped? #t)] ; backslash
         [(= byte 34)                    ; double quote
          (set! in-string? #f)
          (when key-start
            (define key
              (with-handlers ([exn:fail? (lambda (_failure) #f)])
                (bytes->jsexpr (subbytes raw-body key-start (add1 index)))))
            (when (string? key)
              (if (hash-has-key? seen key)
                  (set! duplicate key)
                  (set! seen (hash-set seen key #t))))
            (set! key-start #f)
            (set! expect-key? #f))])]
      [else
       (case byte
         [(34)
          (set! in-string? #t)
          (when (and expect-key? (equal? stack '(123)))
            (set! key-start index))]
         [(123)
          (set! stack (cons byte stack))
          (when (= (length stack) 1)
            (set! expect-key? #t))]
         [(91) (set! stack (cons byte stack))]
         [(125 93)
          (unless (null? stack)
            (set! stack (cdr stack)))]
         [(44)
          (when (equal? stack '(123))
            (set! expect-key? #t))]
         [else (void)])]))
  duplicate)

(define (parse-envelope raw-body environment digest)
  (define duplicate-key (duplicate-top-level-key raw-body))
  (when duplicate-key
    (raise-commerce
     'pancake-payload-invalid
     "verified Pancake webhook payload contains a duplicate top-level field"
     (hash 'payload-digest digest 'field duplicate-key)))
  (define payload
    (with-handlers ([exn:fail?
                     (lambda (_failure)
                       (raise-commerce
                        'pancake-payload-invalid
                        "verified Pancake webhook payload is not valid JSON"
                        (hash 'payload-digest digest)))])
      (bytes->jsexpr raw-body)))
  (unless (hash? payload)
    (raise-commerce
     'pancake-payload-invalid
     "verified Pancake webhook payload must be a JSON object"
     (hash 'payload-digest digest)))
  (for ([field (in-list required-string-fields)])
    (unless (non-empty-string? (hash-ref payload field #f))
      (raise-commerce
       'pancake-payload-invalid
       "verified Pancake webhook payload is missing a required string field"
       (hash 'payload-digest digest 'field field))))
  (unless (hash-has-key? payload 'data)
    (raise-commerce
     'pancake-payload-invalid
     "verified Pancake webhook payload is missing data"
     (hash 'payload-digest digest 'field 'data)))
  (define expected-mode (if (eq? environment 'test) "test" "prod"))
  (unless (equal? (hash-ref payload 'mode #f) expected-mode)
    (raise-commerce
     'pancake-environment-mismatch
     "verified Pancake webhook mode does not match the selected environment"
     (hash 'environment environment 'payload-digest digest)))
  payload)

;; Authenticity-only verification: RSA signature over "<timestamp>.<body>"
;; plus strict post-authentication parsing. Deliberately no freshness window:
;; the timestamp tolerance is an ingestion-time anti-replay concern checked by
;; verify-pancake-webhook, while offline re-verification of journaled evidence
;; must not reject a genuine historical webhook for being old.
(define (verify-pancake-webhook-signature
         raw-body
         signature-header
         #:environment environment
         #:keyring [keyring default-pancake-webhook-keyring])
  (unless (bytes? raw-body)
    (raise-arguments-error
     'verify-pancake-webhook-signature
     "raw-body must be bytes"))
  (unless (environment? environment)
    (raise-argument-error
     'verify-pancake-webhook-signature "(or/c 'test 'production)" environment))
  (unless (pancake-webhook-keyring? keyring)
    (raise-argument-error
     'verify-pancake-webhook-signature "pancake-webhook-keyring?" keyring))

  ;; Copy before authentication so a caller cannot mutate the accepted bytes
  ;; between signature verification and later audit or parsing.
  (define body (bytes->immutable-bytes (bytes-copy raw-body)))
  (define-values (timestamp-text signature-text)
    (parse-signature-header signature-header))
  (define signature-timestamp-ms (parse-timestamp timestamp-text))
  (define public-key
    (parse-public-key (public-key-for keyring environment) environment))
  (define signature (decode-signature signature-text environment))
  (define signed-bytes
    (bytes-append
     (string->bytes/utf-8 timestamp-text)
     #"."
     body))
  (verify-signature public-key signed-bytes signature environment)

  ;; Parsing is intentionally after cryptographic authentication.
  (define digest (payload-digest body))
  (define envelope (parse-envelope body environment digest))
  (pancake-webhook
   environment
   (hash-ref envelope 'id)
   (hash-ref envelope 'timestamp)
   (hash-ref envelope 'eventType)
   (hash-ref envelope 'eventId)
   (hash-ref envelope 'storeId)
   (hash-ref envelope 'storeName)
   (hash-ref envelope 'data)
   body
   digest
   signature-timestamp-ms))

(define (verify-pancake-webhook
         raw-body
         signature-header
         #:environment environment
         #:keyring [keyring default-pancake-webhook-keyring]
         #:now-ms [now-ms
                   (inexact->exact (floor (current-inexact-milliseconds)))]
         #:past-tolerance-ms [past-tolerance-ms default-past-tolerance-ms]
         #:future-tolerance-ms [future-tolerance-ms default-future-tolerance-ms])
  (for ([value (in-list (list now-ms past-tolerance-ms future-tolerance-ms))]
        [description (in-list '("exact-nonnegative-integer? for now-ms"
                                "exact-nonnegative-integer? for past-tolerance-ms"
                                "exact-nonnegative-integer? for future-tolerance-ms"))])
    (unless (exact-nonnegative-integer? value)
      (raise-argument-error 'verify-pancake-webhook description value)))
  (define webhook
    (verify-pancake-webhook-signature
     raw-body signature-header #:environment environment #:keyring keyring))
  (check-timestamp-window
   (pancake-webhook-signature-timestamp-ms webhook)
   now-ms past-tolerance-ms future-tolerance-ms)
  webhook)

;; ---------------------------------------------------------------------------
;; Active one-time order verification

(define pancake-api-endpoint "https://api.waffo.ai/v1/graphql")
(define pancake-api-path "/v1/graphql")
(define default-connect-timeout-seconds 5)
(define default-request-timeout-seconds 10)
(define max-order-response-bytes (* 1024 1024))

(struct pancake-order-binding
  (merchant-external-id product-id offer-id subject-id amount currency-exponent)
  #:transparent
  #:guard
  (lambda (merchant-external-id product-id offer-id subject-id amount
                                currency-exponent who)
    (unless (and (opaque-id? merchant-external-id)
                 (<= (string-length merchant-external-id) 128))
      (raise-argument-error who "non-empty merchant external id up to 128 characters"
                            merchant-external-id))
    (unless (opaque-id? product-id)
      (raise-argument-error who "non-empty opaque provider product id"
                            product-id))
    (unless (stable-id? offer-id)
      (raise-argument-error who "stable kebab-case offer identifier" offer-id))
    (unless (opaque-id? subject-id)
      (raise-argument-error who "non-empty stable subject identifier" subject-id))
    (unless (money? amount)
      (raise-argument-error who "money?" amount))
    (unless (and (exact-integer? currency-exponent)
                 (<= 0 currency-exponent 4))
      (raise-argument-error who "exact integer from 0 through 4"
                            currency-exponent))
    (values merchant-external-id product-id offer-id subject-id amount
            currency-exponent)))

;; Opaque because exposing the fields would expose merchant signing material.
(struct pancake-merchant-client
  (environment merchant-id private-key connect-timeout request-timeout
               transport clock))

(define merchant-id-rx #px"^MER_[A-Za-z0-9]+$")

(define (positive-real? value)
  (and (real? value) (positive? value)))

(define (parse-private-key pem)
  (with-handlers ([exn:fail?
                   (lambda (_failure)
                     (raise-commerce
                      'pancake-merchant-private-key-invalid
                      "Pancake merchant private key is invalid"))])
    (unless (non-empty-string? pem)
      (error 'parse-private-key "empty key"))
    (define normalized
      (string-replace
       (string-replace (string-trim pem) "\\n" "\n") "\r\n" "\n"))
    (define entry
      (call-with-input-string
       normalized
       (lambda (in)
         (read-pem in #:only (list #"PRIVATE KEY" #"RSA PRIVATE KEY")))))
    (when (eof-object? entry)
      (error 'parse-private-key "no supported private key entry"))
    (define format
      (cond
        [(bytes=? (car entry) #"PRIVATE KEY") 'OneAsymmetricKey]
        [(bytes=? (car entry) #"RSA PRIVATE KEY") 'RSAPrivateKey]
        [else (error 'parse-private-key "unsupported private key entry")]))
    (define key
      (datum->pk-key (cdr entry) format (list libcrypto-factory)))
    (unless (and (private-key? key)
                 (equal? (take (pk-key->datum key 'rkt-private) 2)
                         '(rsa private)))
      (error 'parse-private-key "private key is not RSA signing key"))
    key))

(define (default-order-transport endpoint headers body connect-timeout
                                 request-timeout)
  (define response
    (post endpoint
          #:headers headers
          #:data body
          #:timeouts
          (make-timeout-config #:connect connect-timeout
                               #:request request-timeout)
          #:max-attempts 1
          #:max-redirects 0
          #:stream? #t))
  (dynamic-wind
    void
    (lambda ()
      (define response-body-bytes
        (sync/timeout
         request-timeout
         (read-bytes-evt (add1 max-order-response-bytes)
                         (response-output response))))
      (unless response-body-bytes
        (error 'default-order-transport "response body timed out"))
      (when (eof-object? response-body-bytes)
        (set! response-body-bytes #""))
      (when (> (bytes-length response-body-bytes) max-order-response-bytes)
        (raise-commerce
         'pancake-order-response-invalid
         "Pancake order response exceeds the accepted size limit"))
      (values (response-status-code response) response-body-bytes))
    (lambda () (response-close! response))))

(define (make-pancake-merchant-client
         merchant-id private-key-pem
         #:environment environment
         #:connect-timeout-seconds
         [connect-timeout default-connect-timeout-seconds]
         #:request-timeout-seconds
         [request-timeout default-request-timeout-seconds]
         #:transport [transport default-order-transport]
         #:clock [clock current-seconds])
  (unless (and (string? merchant-id) (regexp-match? merchant-id-rx merchant-id))
    (raise-arguments-error
     'make-pancake-merchant-client
     "merchant-id must use Pancake's MER_ identifier format"))
  (unless (environment? environment)
    (raise-argument-error
     'make-pancake-merchant-client "(or/c 'test 'production)" environment))
  (unless (positive-real? connect-timeout)
    (raise-argument-error
     'make-pancake-merchant-client "positive-real? for connect timeout"
     connect-timeout))
  (unless (positive-real? request-timeout)
    (raise-argument-error
     'make-pancake-merchant-client "positive-real? for request timeout"
     request-timeout))
  (unless (procedure? transport)
    (raise-argument-error
     'make-pancake-merchant-client "procedure? for transport" transport))
  (unless (procedure? clock)
    (raise-argument-error
     'make-pancake-merchant-client "procedure? for clock" clock))
  (pancake-merchant-client
   environment merchant-id (parse-private-key private-key-pem)
   connect-timeout request-timeout transport clock))

(define onetime-order-query
  #<<GRAPHQL
query CommerceOnetimeOrder($id: ID!) {
  onetimeOrder(id: $id) {
    id
    status
    testMode
    currency
    orderMerchantExternalId
    store { id }
    onetimeProduct { id }
    payments {
      id
      status
      snapshotAmountDetails { currency total }
    }
  }
}
GRAPHQL
  )

(define (merchant-request-body order-id)
  (jsexpr->bytes
   (hash 'query onetime-order-query
         'variables (hash 'id order-id))))

(define (sign-merchant-request key timestamp body)
  (with-handlers ([exn:fail?
                   (lambda (_failure)
                     (raise-commerce
                      'pancake-request-signing-failed
                      "Pancake merchant request could not be signed"))])
    (parameterize ([crypto-factories (list libcrypto-factory)])
      (define body-hash (digest 'sha256 body))
      (define body-hash-text
        (bytes->string/utf-8 (base64-encode body-hash #:line #f)))
      (define canonical
        (string->bytes/utf-8
         (string-append "POST\n" pancake-api-path "\n" timestamp "\n"
                        body-hash-text)))
      (bytes->string/utf-8
       (base64-encode
        (digest/sign key 'sha256 canonical #:pad 'pkcs1-v1.5)
        #:line #f)))))

(define (request-order client order-id)
  (define now ((pancake-merchant-client-clock client)))
  (unless (exact-nonnegative-integer? now)
    (raise-commerce
     'pancake-request-clock-invalid
     "Pancake merchant request clock did not return UTC epoch seconds"))
  (define timestamp (number->string now))
  (define body (merchant-request-body order-id))
  (define signature
    (sign-merchant-request
     (pancake-merchant-client-private-key client) timestamp body))
  (define headers
    (hash 'content-type "application/json"
          'x-merchant-id (pancake-merchant-client-merchant-id client)
          'x-timestamp timestamp
          'x-signature signature))
  (define-values (status response-body)
    (with-handlers ([exn:fail:commerce? raise]
                    [exn:fail?
                     (lambda (_failure)
                       (raise-commerce
                        'pancake-order-unavailable
                        "Pancake order query is temporarily unavailable"
                        (hash 'retryable? #t)))])
      ((pancake-merchant-client-transport client)
       pancake-api-endpoint headers body
       (pancake-merchant-client-connect-timeout client)
       (pancake-merchant-client-request-timeout client))))
  (unless (and (exact-integer? status) (bytes? response-body))
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order transport returned an invalid response"))
  (when (> (bytes-length response-body) max-order-response-bytes)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response exceeds the accepted size limit"))
  (cond
    [(member status '(401 403))
     (raise-commerce
      'pancake-merchant-authentication-failed
      "Pancake rejected the merchant credentials"
      (hash 'status status 'retryable? #f))]
    [(or (= status 408) (= status 429) (<= 500 status 599))
     (raise-commerce
      'pancake-order-unavailable
      "Pancake order query is temporarily unavailable"
      (hash 'status status 'retryable? #t))]
    [(not (<= 200 status 299))
     (raise-commerce
      'pancake-order-query-rejected
      "Pancake rejected the order query"
      (hash 'status status 'retryable? #f))])
  response-body)

(define (parse-order-response response-body)
  (define envelope
    (with-handlers ([exn:fail?
                     (lambda (_failure)
                       (raise-commerce
                        'pancake-order-response-invalid
                        "Pancake order response is not valid JSON"))])
      (bytes->jsexpr response-body)))
  (unless (hash? envelope)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response must be a JSON object"))
  (define errors (hash-ref envelope 'errors '()))
  (unless (list? errors)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response has an invalid errors field"))
  (unless (null? errors)
    (raise-commerce
     'pancake-order-query-rejected
     "Pancake rejected the GraphQL order query"
     (hash 'error-count (length errors) 'retryable? #f)))
  (define data (hash-ref envelope 'data #f))
  (unless (hash? data)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response is missing GraphQL data"))
  (define order (hash-ref data 'onetimeOrder #f))
  (when (equal? order (json-null))
    (raise-commerce
     'pancake-order-not-found
     "Pancake one-time order was not found"
     (hash 'retryable? #f)))
  (unless (hash? order)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response is missing the one-time order"))
  order)

(define (required-response-string object field)
  (define value (and (hash? object) (hash-ref object field #f)))
  (unless (non-empty-string? value)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response is missing a required string field"
     (hash 'field field)))
  value)

(define (strict-display-amount->minor value exponent)
  (unless (string? value)
    (raise-commerce
     'pancake-amount-invalid
     "Pancake payment total is not a valid display amount"))
  (match (regexp-match #px"^(0|[1-9][0-9]*)(?:[.]([0-9]+))?$" value)
    [(list _ whole fraction)
     (define fraction-text (or fraction ""))
     (when (> (string-length fraction-text) exponent)
       (raise-commerce
        'pancake-amount-invalid
        "Pancake payment total exceeds the configured currency precision"))
     (define padded-fraction
       (string-append
        fraction-text
        (make-string (- exponent (string-length fraction-text)) #\0)))
     (+ (* (string->number whole) (expt 10 exponent))
        (if (string=? padded-fraction "")
            0
            (string->number padded-fraction)))]
    [_
     (raise-commerce
      'pancake-amount-invalid
      "Pancake payment total is not a valid display amount")]))

;; Reconciliation reads provider facts without a webhook and without
;; constructing a canonical event. The snapshot is the minimum the
;; reconciler compares against the order projection.
(struct pancake-order-facts
  (order-id status test-mode payment-id payment-status currency minor-units)
  #:transparent)

(define (read-pancake-onetime-order client order-id)
  (unless (pancake-merchant-client? client)
    (raise-argument-error
     'read-pancake-onetime-order "pancake-merchant-client?" client))
  (unless (non-empty-string? order-id)
    (raise-argument-error
     'read-pancake-onetime-order "non-empty string?" order-id))
  (define order (parse-order-response (request-order client order-id)))
  (define status (required-response-string order 'status))
  (define test-mode (hash-ref order 'testMode 'missing))
  (unless (boolean? test-mode)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response has an invalid testMode field"
     (hash 'field 'testMode)))
  (define payments (hash-ref order 'payments #f))
  (define payment
    (and (list? payments) (pair? payments) (hash? (car payments))
         (car payments)))
  (unless payment
    (raise-commerce
     'pancake-payment-not-found
     "Pancake order response is missing the verified payment"
     (hash)))
  (define amount-details (hash-ref payment 'snapshotAmountDetails #f))
  (unless (hash? amount-details)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response is missing payment amount details"
     (hash 'field 'snapshotAmountDetails)))
  (define currency (required-response-string amount-details 'currency))
  (define total (required-response-string amount-details 'total))
  (pancake-order-facts
   order-id status test-mode
   (required-response-string payment 'id)
   (required-response-string payment 'status)
   currency
   (strict-display-amount->minor total 2)))

(define (webhook-occurred-at timestamp)
  (define matched
    (and (string? timestamp)
         (regexp-match
          #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:[.]([0-9]{1,9}))?Z$"
          timestamp)))
  (unless matched
    (raise-commerce
     'pancake-event-timestamp-invalid
     "Pancake webhook event timestamp is invalid"))
  (define numbers (map string->number (take (cdr matched) 6)))
  (match-define (list year month day hour minute second) numbers)
  (define epoch
    (with-handlers ([exn:fail?
                     (lambda (_failure)
                       (raise-commerce
                        'pancake-event-timestamp-invalid
                        "Pancake webhook event timestamp is invalid"))])
      (find-seconds second minute hour day month year #f)))
  (define normalized (seconds->date epoch #f))
  (unless (and (= year (date-year normalized))
               (= month (date-month normalized))
               (= day (date-day normalized))
               (= hour (date-hour normalized))
               (= minute (date-minute normalized))
               (= second (date-second normalized)))
    (raise-commerce
     'pancake-event-timestamp-invalid
     "Pancake webhook event timestamp is invalid"))
  epoch)

(define (mismatch code message field)
  (raise-commerce code message (hash 'field field 'retryable? #f)))

(define (verify-pancake-onetime-order client webhook binding)
  (unless (pancake-merchant-client? client)
    (raise-argument-error
     'verify-pancake-onetime-order "pancake-merchant-client?" client))
  (unless (pancake-webhook? webhook)
    (raise-argument-error
     'verify-pancake-onetime-order "pancake-webhook?" webhook))
  (unless (pancake-order-binding? binding)
    (raise-argument-error
     'verify-pancake-onetime-order "pancake-order-binding?" binding))
  (unless (string=? (pancake-webhook-event-type webhook) "order.completed")
    (raise-commerce
     'pancake-event-unsupported
     "Pancake webhook is not a supported one-time purchase event"
     (hash 'retryable? #f)))
  (unless (eq? (pancake-merchant-client-environment client)
               (pancake-webhook-environment webhook))
    (mismatch 'pancake-environment-mismatch
              "Pancake merchant client and webhook environments differ"
              'environment))
  (define webhook-data (pancake-webhook-data webhook))
  (unless (hash? webhook-data)
    (raise-commerce
     'pancake-payload-invalid
     "Verified Pancake webhook data must be a JSON object"))
  (define order-id (hash-ref webhook-data 'orderId #f))
  (unless (non-empty-string? order-id)
    (raise-commerce
     'pancake-payload-invalid
     "Verified Pancake webhook data is missing orderId"
     (hash 'field 'orderId)))
  (define occurred-at (webhook-occurred-at (pancake-webhook-timestamp webhook)))

  (define order (parse-order-response (request-order client order-id)))
  (define actual-order-id (required-response-string order 'id))
  (define status (required-response-string order 'status))
  (define test-mode (hash-ref order 'testMode 'missing))
  (unless (boolean? test-mode)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response has an invalid testMode field"
     (hash 'field 'testMode)))
  (define currency (required-response-string order 'currency))
  (define external-id
    (required-response-string order 'orderMerchantExternalId))
  (define store-id
    (required-response-string (hash-ref order 'store #f) 'id))
  (define product-id
    (required-response-string (hash-ref order 'onetimeProduct #f) 'id))
  (define payments (hash-ref order 'payments #f))
  (unless (list? payments)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response has an invalid payments field"
     (hash 'field 'payments)))
  (define matching-payments
    (filter
     (lambda (payment)
       (and (hash? payment)
            (equal? (hash-ref payment 'id #f)
                    (pancake-webhook-event-id webhook))))
     payments))
  (when (null? matching-payments)
    (mismatch 'pancake-payment-not-found
              "Pancake webhook payment was not found on the active order"
              'payment-id))
  (unless (= (length matching-payments) 1)
    (raise-commerce
     'pancake-order-response-invalid
     "Pancake order response contains duplicate payment identifiers"
     (hash 'field 'payments)))
  (define payment (car matching-payments))
  (define payment-status (required-response-string payment 'status))
  (define amount-details (hash-ref payment 'snapshotAmountDetails #f))
  (define payment-currency
    (required-response-string amount-details 'currency))
  (define payment-total
    (required-response-string amount-details 'total))

  (unless (string=? actual-order-id order-id)
    (mismatch 'pancake-order-id-mismatch
              "Pancake active order id does not match the webhook"
              'order-id))
  (unless (string=? status "completed")
    (mismatch 'pancake-order-status-mismatch
              "Pancake one-time order is not completed"
              'status))
  (unless (eq? test-mode
               (eq? (pancake-webhook-environment webhook) 'test))
    (mismatch 'pancake-environment-mismatch
              "Pancake active order environment does not match the webhook"
              'testMode))
  (unless (string=? store-id (pancake-webhook-store-id webhook))
    (mismatch 'pancake-store-mismatch
              "Pancake active order store does not match the webhook"
              'store-id))
  (unless (string=? external-id
                    (pancake-order-binding-merchant-external-id binding))
    (mismatch 'pancake-order-binding-mismatch
              "Pancake active order does not match the checkout binding"
              'orderMerchantExternalId))
  (unless (string=? product-id (pancake-order-binding-product-id binding))
    (mismatch 'pancake-product-mismatch
              "Pancake active order product does not match the Offer mapping"
              'product-id))
  (define expected-money (pancake-order-binding-amount binding))
  (unless (and (string=? currency (money-currency expected-money))
               (string=? payment-currency (money-currency expected-money)))
    (mismatch 'pancake-currency-mismatch
              "Pancake active order currency does not match the Offer"
              'currency))
  (unless (string=? payment-status "succeeded")
    (mismatch 'pancake-payment-status-mismatch
              "Pancake active order payment is not succeeded"
              'payment-status))
  (define actual-minor
    (strict-display-amount->minor
     payment-total (pancake-order-binding-currency-exponent binding)))
  (unless (= actual-minor (money-minor-units expected-money))
    (mismatch 'pancake-amount-mismatch
              "Pancake active payment amount does not match the Offer"
              'amount))

  (make-verified-payment-event
   "pancake"
   (pancake-webhook-id webhook)
   (pancake-webhook-payload-digest webhook)
   'payment-succeeded
   order-id
   (pancake-order-binding-offer-id binding)
   (pancake-order-binding-subject-id binding)
   expected-money
   occurred-at
   #:paid-through #f))
