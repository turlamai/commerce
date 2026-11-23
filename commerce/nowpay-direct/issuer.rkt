#lang racket/base

;; An issuer-owned live query and private lineage ledger. This is deliberately
;; separate from the payment journal and cannot ingest an edge-supplied ALLOW.
(require db json file/sha1 racket/port permit/issuer
         "../nowpay-direct.rkt" (submod "../nowpay-direct.rkt" internal)
         "../private/model.rkt" "../private/time.rkt")
(provide make-nowpay-direct-issuer authorize-nowpay-direct)
(struct direct-issuer (client db issuer service product edition key key-id trust clock purchasing? buyers))
(define (refuse code)
  (raise (exn:fail:commerce "NowPay Direct authorization refused" (current-continuation-marks) code (hash))))
(define (make-nowpay-direct-issuer #:client client #:database db #:issuer issuer
         #:service-id service #:product-id product #:edition edition
         #:private-key key #:key-id kid #:trust-store trust
         #:clock [clock current-seconds] #:purchasing-enabled? [purchasing? #f]
         #:purchase-buyer-allowlist [buyers #f])
  (unless (and (nowpay-direct-client? client) (connection? db) (string? issuer)
               (string? service) (string? product) (string? edition) (boolean? purchasing?)
               (or (not buyers) (and (list? buyers) (andmap string? buyers))))
    (refuse 'nowpay-direct-configuration-invalid))
  (query-exec db "PRAGMA busy_timeout=45000")
  (query-exec db "PRAGMA journal_mode=WAL")
  (query-exec db "PRAGMA synchronous=FULL")
  (query-exec db "CREATE TABLE IF NOT EXISTS direct_lineages (scope TEXT PRIMARY KEY, revision INTEGER NOT NULL)")
  (query-exec db "CREATE TABLE IF NOT EXISTS direct_authorizations (nonce TEXT PRIMARY KEY, request_digest TEXT NOT NULL, deadline INTEGER NOT NULL, response BLOB NOT NULL, provider_raw BLOB NOT NULL)")
  (query-exec db "CREATE TRIGGER IF NOT EXISTS direct_no_update BEFORE UPDATE ON direct_authorizations BEGIN SELECT RAISE(ABORT, 'immutable direct observation'); END")
  (query-exec db "CREATE TRIGGER IF NOT EXISTS direct_no_delete BEFORE DELETE ON direct_authorizations BEGIN SELECT RAISE(ABORT, 'immutable direct observation'); END")
  (direct-issuer client db issuer service product edition key kid trust clock purchasing? buyers))
(define (digest value) (bytes->hex-string (sha256-bytes value)))

(define (authorize-nowpay-direct service request)
  (unless (and (direct-issuer? service) (hash? request)
               (equal? (sort (hash-keys request) symbol<?) '(buyer_id nonce service_id version))
               (equal? (hash-ref request 'version #f) 1)
               (equal? (hash-ref request 'service_id #f) (direct-issuer-service service))
               (string? (hash-ref request 'nonce #f))
               (regexp-match? #px"^[a-f0-9]{64}$" (hash-ref request 'nonce))
               (string? (hash-ref request 'buyer_id #f)))
    (refuse 'nowpay-direct-request-invalid))
  (define buyer (hash-ref request 'buyer_id))
  (define nonce (hash-ref request 'nonce))
  (define request-digest (digest (string->bytes/utf-8 (jsexpr->string (list (direct-issuer-service service) buyer nonce)))))
  (define db (direct-issuer-db service))
  (call-with-transaction db
   (lambda ()
     (define now ((direct-issuer-clock service)))
     (define previous (query-maybe-row db "SELECT request_digest, deadline, response FROM direct_authorizations WHERE nonce=?" nonce))
     (cond
       [previous
        (unless (and (equal? (vector-ref previous 0) request-digest) (< now (vector-ref previous 1)))
          (refuse 'nowpay-direct-request-replayed))
        (read-json (open-input-bytes (vector-ref previous 2)))]
       [else
        (define access (nowpay-direct-purchase-consult (direct-issuer-client service) buyer))
        (define decision (nowpay-access-decision access))
        (define observed ((direct-issuer-clock service)))
        (define deadline (+ observed 30))
        (define base (hasheq 'version 1 'nonce nonce 'buyer_id buyer 'decision decision))
        (define result
          (cond
            [(equal? decision "ALLOW")
             (define scope (digest (string->bytes/utf-8 (jsexpr->string
               (list (direct-issuer-issuer service) (direct-issuer-service service)
                     (nowpay-access-product-id access) buyer)))))
             (define old-revision (query-maybe-value db "SELECT revision FROM direct_lineages WHERE scope=?" scope))
             (define revision (if old-revision (add1 old-revision) 0))
             (unless (<= revision 9007199254740991) (refuse 'nowpay-direct-revision-invalid))
             (define from (epoch-seconds->rfc3339 (nowpay-access-valid-from access)))
             (define until (epoch-seconds->rfc3339 (nowpay-access-valid-until access)))
             (define claims
               (entitlement-payload #:issuer (direct-issuer-issuer service)
                #:credential-id (string-append "direct-cred-" nonce)
                #:entitlement-id (string-append "direct-ent-" scope) #:revision revision
                #:subject (subject #:type "account" #:id buyer)
                #:grants (list (grant #:products (list (direct-issuer-product service)) #:edition (direct-issuer-edition service)))
                #:constraints (constraints #:use-expires-at until)
                #:issued-at (epoch-seconds->rfc3339 observed) #:not-before from
                #:extensions (hasheq 'jrtx.site/commerce/nowpay-direct
                  (hasheq 'version 1 'request_nonce nonce 'service_id (direct-issuer-service service)
                   'provider_product_id (nowpay-access-product-id access)
                   'valid_from from 'valid_until until
                   'observed_at (epoch-seconds->rfc3339 observed)
                   'fresh_until (epoch-seconds->rfc3339 deadline)))))
             (define credential (issue-credential (payload->bytes claims) (direct-issuer-key service)
               (direct-issuer-key-id service) (direct-issuer-trust service)))
             (define encoded (open-output-bytes))
             (write-issued-credential credential encoded)
             (query-exec db "INSERT INTO direct_lineages(scope,revision) VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET revision=excluded.revision" scope revision)
             (hash-set base 'credential (read-json (open-input-bytes (get-output-bytes encoded))))]
            [(and (equal? decision "PURCHASE_REQUIRED") (direct-issuer-purchasing? service)
                  (or (not (direct-issuer-buyers service)) (member buyer (direct-issuer-buyers service))))
             (define catalog (nowpay-direct-charge-query (direct-issuer-client service)))
             (if (nowpay-charge-purchasable? catalog)
                 (hash-set (hash-set base 'purchase_url (or (nowpay-access-purchase-url access) 'null))
                           'purchase_qr_code (or (nowpay-access-qr-code access) 'null))
                 base)]
            [else base]))
        ;; Commit the authenticated observation and exact delivered envelope
        ;; atomically before the local product can observe a credential.
        (query-exec db "INSERT INTO direct_authorizations(nonce,request_digest,deadline,response,provider_raw) VALUES(?,?,?,?,?)"
          nonce request-digest deadline (string->bytes/utf-8 (jsexpr->string result)) (nowpay-access-raw access))
        result]))
   #:option 'immediate))
