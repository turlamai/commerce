#lang racket/base

;; Transport-neutral, authenticated service-request boundary.
;; This does not open a public HTTP route or store replay state: the HTTP
;; adapter must supply the observed method/path/body and a durable atomic
;; claim-once! operation. Secrets come from a trusted service registry only.
(provide hosted-request-mac verify-hosted-service-request)

(require crypto
         crypto/libcrypto
         racket/list)

(define (bounded-string? value maximum)
  (and (string? value)
       (<= 1 (string-length value) maximum)))

(define (valid-nonce? nonce)
  (and (string? nonce)
       (regexp-match? #px"^[A-Za-z0-9_-]{16,128}$" nonce)))

(define (check-request-fields who service-id method path timestamp nonce
                              issuer subject-type subject-id offer-id product-id body)
  (for ([name/value
         (in-list
          (list (cons "service-id" service-id)
                (cons "issuer" issuer)
                (cons "subject-type" subject-type)
                (cons "subject-id" subject-id)
                (cons "offer-id" offer-id)
                (cons "product-id" product-id)))])
    (unless (bounded-string? (cdr name/value) 256)
      (raise-arguments-error who "invalid bounded scope identifier"
                             "field" (car name/value))))
  (unless (bounded-string? method 16)
    (raise-argument-error who "HTTP method up to 16 characters" method))
  (unless (bounded-string? path 2048)
    (raise-argument-error who "request path up to 2048 characters" path))
  (unless (exact-nonnegative-integer? timestamp)
    (raise-argument-error who "exact-nonnegative-integer?" timestamp))
  (unless (valid-nonce? nonce)
    (raise-argument-error who "16-128 character base64url nonce" nonce))
  (unless (and (bytes? body) (<= (bytes-length body) 1048576))
    (raise-argument-error who "request body bytes up to 1 MiB" body)))

;; Length-framed, version/domain-separated binary encoding prevents ambiguity
;; even when a signed field contains ':' or a newline. The HTTP gateway must
;; sign the exact method, path and raw body observed by its HTTP parser.
(define (request-bytes service-id method path timestamp nonce
                       issuer subject-type subject-id offer-id product-id body)
  (check-request-fields 'request-bytes
                        service-id method path timestamp nonce
                        issuer subject-type subject-id offer-id product-id body)
  (define parts
    (append (map string->bytes/utf-8
                 (list service-id method path (number->string timestamp)
                       nonce issuer subject-type subject-id offer-id product-id))
            (list body)))
  (for/fold ([out #"commerce-hosted-s2s-v1\n"]) ([part (in-list parts)])
    (bytes-append out
                  (string->bytes/utf-8 (number->string (bytes-length part)))
                  #":" part)))

(define (valid-secret? key)
  (and (bytes? key) (<= 32 (bytes-length key))))

(define (hosted-request-mac key
                            #:service-id service-id
                            #:method method #:path path
                            #:timestamp timestamp #:nonce nonce
                            #:issuer issuer #:subject-type subject-type
                            #:subject-id subject-id #:offer-id offer-id
                            #:product-id product-id #:body body)
  (unless (valid-secret? key)
    (raise-argument-error 'hosted-request-mac
                          "service HMAC key of at least 32 bytes" key))
  (parameterize ([crypto-factories (list libcrypto-factory)])
    (hmac 'sha256 key
          (request-bytes service-id method path timestamp nonce
                         issuer subject-type subject-id offer-id product-id
                         body))))

;; Equal-length MAC check with no early return based on secret byte content.
(define (same-mac? received expected)
  (and (bytes? received)
       (= (bytes-length received) 32)
       (= (bytes-length expected) 32)
       (zero?
        (for/fold ([difference 0]) ([a (in-bytes received)]
                                    [b (in-bytes expected)])
          (bitwise-ior difference (bitwise-xor a b))))))

;; Returns #t only after signature, scoped service authorization, and replay
;; admission succeed. resolve-key: service-id -> server-held key bytes or #f.
;; allow-scope: service-id issuer subject-type subject-id offer-id product-id -> #t.
;; claim-once!: service-id nonce expires-at -> #t, atomically and durably.
;; The nonce expires after timestamp+window, not just now+window, so a
;; future-dated signed request cannot be replayed as the entry ages out.
(define (verify-hosted-service-request
         #:service-id service-id
         #:method method #:path path
         #:timestamp timestamp #:nonce nonce
         #:issuer issuer #:subject-type subject-type
         #:subject-id subject-id #:offer-id offer-id
         #:product-id product-id #:body body
         #:mac mac #:resolve-key resolve-key
         #:allow-scope allow-scope #:claim-once! claim-once!
         #:now now #:window-seconds [window 300])
  (unless (and (procedure? resolve-key)
               (procedure-arity-includes? resolve-key 1)
               (procedure? allow-scope)
               (procedure-arity-includes? allow-scope 6)
               (procedure? claim-once!)
               (procedure-arity-includes? claim-once! 3))
    (raise-argument-error
     'verify-hosted-service-request
     "resolver, scope authorizer and replay claimer with supported arities"
     (list resolve-key allow-scope claim-once!)))
  (unless (and (exact-nonnegative-integer? now)
               (exact-positive-integer? window)
               (<= window 900))
    (raise-arguments-error
     'verify-hosted-service-request "invalid trusted time or replay window"
     "now" now "window" window))
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define raw
      (request-bytes service-id method path timestamp nonce
                     issuer subject-type subject-id offer-id product-id body))
    (and (<= (abs (- timestamp now)) window)
         (bytes? mac) (= (bytes-length mac) 32)
         (let ([key (resolve-key service-id)])
           (and (valid-secret? key)
                (let ([expected
                       (parameterize
                           ([crypto-factories (list libcrypto-factory)])
                         (hmac 'sha256 key raw))])
                  (and (same-mac? mac expected)
                       (eq? #t (allow-scope
                                service-id issuer subject-type subject-id
                                offer-id product-id))
                       (eq? #t (claim-once! service-id nonce
                                           (+ timestamp window 1))))))))))
