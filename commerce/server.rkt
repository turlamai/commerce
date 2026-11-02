#lang racket/base

(provide
 webhook-endpoint?
 make-webhook-endpoint
 handle-webhook-post
 handle-claim-post
 handle-readyz
 serve-webhook-endpoint)

(require json
         net/url
         racket/list
         (only-in permit/envelope envelope->jsexpr read-envelope)
         "health.rkt"
         web-server/http
         web-server/servlet-env
         "journal.rkt"
         "pancake.rkt"
         "storage.rkt"
         "private/model.rkt")

;; The HTTP edge is a thin shell: it authenticates the exact webhook bytes,
;; resolves the durable checkout expectation, actively verifies the order,
;; journals the canonical event, and acknowledges. Every commerce invariant
;; (idempotent acceptance, conflicting-replay rejection, no inline
;; issuance) lives in the boundaries below; this module only maps typed
;; failures onto HTTP status codes.

(struct webhook-endpoint
  (keyring environment merchant-client binding-lookup storage)
  #:transparent)

(define (make-webhook-endpoint
         #:keyring keyring
         #:environment environment
         #:merchant-client merchant-client
         #:binding-lookup binding-lookup
         #:storage storage)
  (unless (pancake-webhook-keyring? keyring)
    (raise-argument-error
     'make-webhook-endpoint "pancake-webhook-keyring?" keyring))
  (unless (memq environment '(test production))
    (raise-argument-error
     'make-webhook-endpoint "(or/c 'test 'production)" environment))
  (unless (pancake-merchant-client? merchant-client)
    (raise-argument-error
     'make-webhook-endpoint "pancake-merchant-client?" merchant-client))
  (unless (procedure? binding-lookup)
    (raise-argument-error
     'make-webhook-endpoint "procedure?" binding-lookup))
  (unless (commerce-storage? storage)
    (raise-argument-error
     'make-webhook-endpoint "commerce-storage?" storage))
  (webhook-endpoint keyring environment merchant-client binding-lookup
                    storage))

(define (http-error code payload)
  (values code (jsexpr->bytes payload)))

;; Pure webhook handling: exact body bytes plus the signature header in.
;; Returns (values status json-body). The order is deliberate: signature
;; first, then binding resolution, then active verification, then journal
;; acceptance — and the journal's idempotence decides the acknowledgement.
(define (handle-webhook-post endpoint raw-body signature-header)
  (unless (bytes? raw-body)
    (raise-argument-error 'handle-webhook-post "bytes?" raw-body))
  (unless (string? signature-header)
    (raise-argument-error
     'handle-webhook-post "string?" signature-header))
  (define storage (webhook-endpoint-storage endpoint))
  (with-handlers
      ([exn:fail:commerce?
        (lambda (failure)
          (define code (exn:fail:commerce-code failure))
          (cond
            [(panic-auth-code? code)
             (http-error
              401 (hash 'accepted #f 'error "unauthenticated"))]
            [(eq? code 'pancake-order-unavailable)
             (http-error
              503 (hash 'accepted #f 'error "provider-unavailable"))]
            [(eq? code 'event-conflict)
             (http-error
              409 (hash 'accepted #f 'error "conflicting-replay"))]
            [(eq? code 'unknown-checkout-binding)
             (http-error
              404 (hash 'accepted #f 'error "unknown-checkout"))]
            [else
             ;; Semantic mismatches between webhook, active order, and
             ;; checkout expectation are durable rejections.
             (http-error
              422 (hash 'accepted #f 'error "semantic-mismatch"))]))])
    (define webhook
      (verify-pancake-webhook
       raw-body signature-header
       #:environment (webhook-endpoint-environment endpoint)
       #:keyring (webhook-endpoint-keyring endpoint)))
    (define binding
      ((webhook-endpoint-binding-lookup endpoint)
       (hash-ref (pancake-webhook-data webhook) 'orderId)))
    (unless binding
      (raise-commerce
       'unknown-checkout-binding
       "webhook order has no durable checkout binding"
       (hash)))
    (define event
      (verify-pancake-onetime-order
       (webhook-endpoint-merchant-client endpoint) webhook
       ;; The durable expectation is provider-neutral; the server owns the
       ;; adaptation to the provider-native binding shape.
       (pancake-order-binding
        (checkout-binding-merchant-external-id binding)
        (checkout-binding-product-id binding)
        (checkout-binding-offer-id binding)
        (checkout-binding-subject-id binding)
        (money (checkout-binding-currency binding)
               (checkout-binding-amount-minor-units binding))
        (checkout-binding-currency-exponent binding))))
    ;; Journal the exact signature evidence the issuer role needs to
    ;; re-verify this row offline (ADR-0020): the environment tag selects the
    ;; keyring entry and the header carries the t/v1 fields it authenticated.
    (define signature-evidence
      (jsexpr->bytes
       (hasheq 'environment
               (symbol->string (webhook-endpoint-environment endpoint))
               'signature_header signature-header)))
    (define acceptance
      (journal-accept! storage
                       (pancake-webhook-raw-body webhook) event
                       #:received-at (current-seconds)
                       #:evidence signature-evidence))
    (http-error
     200
     (hash 'accepted #t
           'disposition
           (symbol->string (journal-acceptance-disposition acceptance))))))

;; Authentication-family failures: the request never proved itself, so it
;; gets 401 and no evidence is created. Semantic mismatches between the
;; authenticated webhook, the active order, and the durable expectation
;; are durable rejections (422) an operator reviews.
(define (panic-auth-code? code)
  (memq
   code
   '(pancake-signature-header-missing pancake-signature-header-malformed
     pancake-timestamp-invalid pancake-timestamp-outside-tolerance
     pancake-signature-invalid pancake-public-key-invalid
     pancake-payload-invalid)))

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce message (current-continuation-marks) code data)))

;; Readiness probe: the read-only health snapshot rendered as JSON.
;; Registers as a cheap GET for load balancers and supervisors.
(define (handle-readyz endpoint)
  (define report
    (health-report (webhook-endpoint-storage endpoint)
                   #:now (current-seconds)))
  (define snapshot (health-status-readiness report))
  (http-error
   (if (null? (health-status-warnings report)) 200 503)
   (hash 'schema-version (readiness-schema-version snapshot)
         'journal-unprojected (readiness-journal-unprojected snapshot)
         'projection-blocked (readiness-projection-blocked snapshot)
         'work-pending (readiness-work-pending snapshot)
         'work-processing (readiness-work-processing snapshot)
         'work-stale-lease (readiness-work-stale-lease snapshot)
         'claim-window-passed (readiness-claim-window-passed snapshot)
         'warnings (map health-warning-code
                        (health-status-warnings report)))))

;; Claim portal handling: the customer's one-time token in, the exact
;; signed Permit envelope out. Token presence is the only authorization;
;; wrong, reused, and expired tokens fail typed and mutate nothing.
;; Fulfillment never creates or advances a lineage revision.
(define (handle-claim-post endpoint token)
  (unless (string? token)
    (raise-argument-error 'handle-claim-post "string?" token))
  (with-handlers
      ([exn:fail:commerce?
        (lambda (failure)
          (define code (exn:fail:commerce-code failure))
          (cond
            [(eq? code 'claim-not-found)
             (http-error 404 (hash 'fulfilled #f 'error "unknown-claim"))]
            [(eq? code 'claim-already-claimed)
             (http-error
              409 (hash 'fulfilled #f 'error "already-claimed"))]
            [(eq? code 'claim-expired)
             (http-error
              410 (hash 'fulfilled #f 'error "claim-expired"))]
            [else
             (http-error
              422 (hash 'fulfilled #f 'error "claim-refused"))]))])
    (define fulfillment
      (storage-claim-credential (webhook-endpoint-storage endpoint)
                                #:token token
                                #:now (current-seconds)))
    (define envelope
      (read-envelope
       (open-input-bytes
        (issued-credential-record-envelope-bytes
         (claim-fulfillment-credential fulfillment)))))
    (http-error 200 (envelope->jsexpr envelope))))

(define (signature-header-value raw-headers)
  (define header (headers-assq* #"x-waffo-signature" raw-headers))
  (and header (bytes->string/utf-8 (header-value header))))

;; Binds the endpoint to an HTTP port. Returns a zero-argument shutdown
;; procedure. The servlet path is the only route; anything else is 404.
(define (serve-webhook-endpoint endpoint
                                #:port port
                                #:listen-ip [listen-ip "127.0.0.1"])
  (define endpoint-custodian (make-custodian))
  (parameterize ([current-custodian endpoint-custodian])
    (serve/servlet
     (lambda (request)
       (define request-url (url->string (request-uri request)))
       (define path
         (cond
           [(regexp-match? #rx"/webhooks/pancake$" request-url)
            "/webhooks/pancake"]
           [(regexp-match? #rx"/claims$" request-url) "/claims"]
           [(regexp-match? #rx"/readyz$" request-url) "/readyz"]
           [else request-url]))
       (cond
         [(equal? path "/webhooks/pancake")
          (define raw
            (or (request-post-data/raw request) #""))
          (define signature
            (signature-header-value (request-headers/raw request)))
          (define-values (status body)
            (handle-webhook-post endpoint raw signature))
          (json-response status body)]
         [(equal? path "/readyz")
          (define-values (status body) (handle-readyz endpoint))
          (json-response status body)]
         [(equal? path "/claims")
          (define token
            (let ([raw (or (request-post-data/raw request) #"")])
              (with-handlers
                  ([exn:fail? (lambda (_) #f)])
                (hash-ref (string->jsexpr (bytes->string/utf-8 raw))
                          'token #f))))
          (define-values (status body)
            (if token
                (handle-claim-post endpoint token)
                (http-error
                 422 (hash 'fulfilled #f 'error "invalid-claim-request"))))
          (json-response status body)]
         [else
          (json-response 404 (jsexpr->bytes (hash 'error "not-found")))]))
     #:port port
     #:listen-ip listen-ip
     #:command-line? #f
     #:servlet-path "/webhooks/pancake"
     #:servlet-regexp #rx"^/webhooks/pancake$|^/claims$|^/readyz$"))
  (lambda ()
    (custodian-shutdown-all endpoint-custodian)))

(define (json-response status body)
  (response/full
   status
   #"commerce-endpoint"
   (current-seconds)
   #"application/json"
   '()
   (list body)))
