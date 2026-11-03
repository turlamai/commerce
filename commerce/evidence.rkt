#lang racket/base

;; Issuer-side re-verification of journaled payment evidence: the durable
;; verified-evidence boundary named by ADR-0020. A claimed outbox row may only
;; induce signing when the journal row it was projected from carries payment
;; bytes the issuer can re-authenticate offline with issuer-held *public*
;; keys, whose re-derived facts match the stored canonical event, whose
;; subject and Offer match both the claimed outbox intent and the append-only
;; checkout binding, and whose amount equals the pinned catalog price of the
;; claimed Offer. A compromised HTTP edge that writes forged journal, outbox,
;; or projection rows therefore cannot obtain a credential for a subject or
;; Offer that the signed bytes, the binding, and the catalog do not agree on.
;;
;; Refund rows (issue #38): withdrawal intents verify the journaled signed
;; refund-query proof the same way, closing the forged-refund denial-of-
;; service window for providers with offline refund verification.
;;
;; This module runs inside the issuer role. It consumes no merchant private
;; key, makes no network request, and never trusts the edge's derived fields
;; beyond comparing them against what the signed bytes, the binding, and the
;; pinned catalog independently establish.
(provide issuance-evidence-verifier?
         make-issuance-evidence-verifier
         verify-issuance-evidence!)

(require json
         racket/match
         racket/string
         "alipay.rkt"
         "alipay/refund.rkt"
         "pancake.rkt"
         "permit.rkt"
         "private/journal-model.rkt"
         "private/model.rkt"
         "storage.rkt")

(define (raise-commerce code message [data (hash)])
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

;; Deliberately opaque: verifier configuration is deployment material and
;; must never leak through diagnostic printing. The binding lookup reads the
;; append-only checkout binding table; it must not be able to mutate it.
(struct issuance-evidence-verifier (catalog alipay-public-key-pem
                                            pancake-keyring binding-lookup))

(define max-evidence-bytes 4096)

(define (make-issuance-evidence-verifier
         #:catalog catalog
         #:alipay-public-key-pem [alipay-public-key-pem #f]
         #:pancake-keyring [pancake-keyring default-pancake-webhook-keyring]
         #:binding-lookup [binding-lookup #f])
  (unless (permit-policy-catalog? catalog)
    (raise-argument-error
     'make-issuance-evidence-verifier "permit-policy-catalog?" catalog))
  (unless (or (not alipay-public-key-pem)
              (and (string? alipay-public-key-pem)
                   (positive? (string-length alipay-public-key-pem))))
    (raise-argument-error
     'make-issuance-evidence-verifier
     "(or/c #f non-empty-string?) for the trusted Alipay public PEM"
     alipay-public-key-pem))
  (unless (pancake-webhook-keyring? pancake-keyring)
    (raise-argument-error
     'make-issuance-evidence-verifier "pancake-webhook-keyring?" pancake-keyring))
  (unless (or (not binding-lookup)
              (and (procedure? binding-lookup)
                   (procedure-arity-includes? binding-lookup 1)))
    (raise-argument-error
     'make-issuance-evidence-verifier
     "(or/c #f (procedure/c stable-id? (or/c checkout-binding? #f)))"
     binding-lookup))
  (issuance-evidence-verifier
   catalog alipay-public-key-pem pancake-keyring binding-lookup))

;; Fences the claimed outbox intent against the journaled event and the
;; pinned catalog. The claimed Offer must equal the journal event's Offer,
;; the claimed subject must equal the journal event's subject, and the
;; amount must equal the catalog price — so neither a retargeted pending row
;; nor a forged journal subject can steer the anchor away from the bytes.
(define (verify-catalog-and-claim! verifier record claimed-offer-id
                                   claimed-subject-id)
  (define event (journal-record-event record))
  (define sequence (journal-record-sequence record))
  (unless (string=? (payment-event-offer-id event) claimed-offer-id)
    (raise-commerce
     'evidence-field-mismatch
     "claimed outbox Offer does not match the journaled payment evidence"
     (hash 'field 'offer-id
           'journaled (payment-event-offer-id event)
           'claimed claimed-offer-id
           'sequence sequence)))
  (unless (string=? (payment-event-subject-id event) claimed-subject-id)
    (raise-commerce
     'evidence-field-mismatch
     "claimed outbox subject does not match the journaled payment evidence"
     (hash 'field 'subject-id
           'journaled (payment-event-subject-id event)
           'claimed claimed-subject-id
           'sequence sequence)))
  (define offer
    (permit-catalog-offer
     (issuance-evidence-verifier-catalog verifier)
     claimed-offer-id))
  (unless offer
    (raise-commerce
     'evidence-unknown-offer
     "payment evidence claims an Offer the pinned catalog does not sell"
     (hash 'offer-id claimed-offer-id
           'sequence sequence)))
  (define price (offer-price offer))
  (define amount (payment-event-amount event))
  (unless (and (string=?
                (money-currency price) (money-currency amount))
               (= (money-minor-units price) (money-minor-units amount)))
    (raise-commerce
     'evidence-amount-offer-mismatch
     "payment evidence amount does not match the pinned Offer price"
     (hash 'offer-id claimed-offer-id
           'expected-currency (money-currency price)
           'expected-minor-units (money-minor-units price)
           'evidence-currency (money-currency amount)
           'evidence-minor-units (money-minor-units amount)
           'sequence sequence))))

;; The append-only checkout binding is the only durable record of which
;; subject the out_trade_no was minted for. Re-deriving the subject from it
;; (rather than trusting the journal row) closes the forged-journal redirect.
(define (verify-binding! verifier record expected-amount)
  (define event (journal-record-event record))
  (define sequence (journal-record-sequence record))
  (define lookup
    (issuance-evidence-verifier-binding-lookup verifier))
  (unless (procedure? lookup)
    (raise-commerce
     'evidence-verifier-unconfigured
     "no checkout binding lookup is configured for evidence re-verification"
     (hash 'sequence sequence)))
  (define binding (lookup (payment-event-order-id event)))
  (unless (checkout-binding? binding)
    (raise-commerce
     'evidence-binding-missing
     "journaled order has no durable checkout binding"
     (hash 'order-id (payment-event-order-id event)
           'sequence sequence)))
  (unless (and (string=? (checkout-binding-offer-id binding)
                         (payment-event-offer-id event))
               (string=? (checkout-binding-subject-id binding)
                         (payment-event-subject-id event))
               (string=? (checkout-binding-currency binding)
                         (money-currency expected-amount))
               (= (checkout-binding-amount-minor-units binding)
                  (money-minor-units expected-amount)))
    (raise-commerce
     'evidence-binding-mismatch
     "journaled payment facts disagree with the durable checkout binding"
     (hash 'order-id (payment-event-order-id event)
           'binding-offer (checkout-binding-offer-id binding)
           'binding-subject (checkout-binding-subject-id binding)
           'evidence-offer (payment-event-offer-id event)
           'evidence-subject (payment-event-subject-id event)
           'sequence sequence))))

(define (alipay-notification-matches! notice record)
  (define event (journal-record-event record))
  (define sequence (journal-record-sequence record))
  (unless (string=? (alipay-notification-order-id notice)
                    (payment-event-order-id event))
    (raise-commerce
     'evidence-field-mismatch
     "verified Alipay notification out_trade_no does not match the journal row"
     (hash 'field 'order-id
           'sequence sequence)))
  (unless (string=? (alipay-notification-status notice) "TRADE_SUCCESS")
    (raise-commerce
     'evidence-field-mismatch
     "verified Alipay notification is not a successful trade"
     (hash 'field 'trade-status
           'status (alipay-notification-status notice)
           'sequence sequence)))
  (unless (= (alipay-notification-amount notice)
             (money-minor-units (payment-event-amount event)))
    (raise-commerce
     'evidence-field-mismatch
     "verified Alipay notification amount does not match the journal row"
     (hash 'field 'amount
           'sequence sequence)))
  (unless (string=? (money-currency (payment-event-amount event)) "CNY")
    (raise-commerce
     'evidence-field-mismatch
     "Alipay evidence must be a CNY payment"
     (hash 'field 'currency
           'sequence sequence))))

(define (parse-pancake-evidence raw-evidence)
  (unless (<= (bytes-length raw-evidence) max-evidence-bytes)
    (raise-commerce
     'evidence-unverifiable
     "Pancake signature evidence exceeds the bounded size"
     (hash)))
  (define parsed
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (read-json (open-input-bytes raw-evidence))))
  (unless (and (hash? parsed)
               (equal? (sort (hash-keys parsed) symbol<?)
                       '(environment signature_header)))
    (raise-commerce
     'evidence-unverifiable
     "Pancake signature evidence has an unexpected schema"
     (hash)))
  (define environment (hash-ref parsed 'environment))
  (define signature-header (hash-ref parsed 'signature_header))
  (unless (and (member environment '("test" "production"))
               (string? signature-header)
               (<= 1 (string-length signature-header) 1024))
    (raise-commerce
     'evidence-unverifiable
     "Pancake signature evidence has invalid fields"
     (hash)))
  (values (string->symbol environment) signature-header))

(define (pancake-webhook-matches! webhook record)
  (define event (journal-record-event record))
  (define sequence (journal-record-sequence record))
  (unless (string=? (pancake-webhook-id webhook)
                    (payment-event-event-id event))
    (raise-commerce
     'evidence-field-mismatch
     "verified Pancake webhook id does not match the journal event"
     (hash 'field 'event-id
           'sequence sequence))))

;; Recovers the immutable out_request_no from the refund event id minted by
;; journal-alipay-full-refund!, then re-authenticates the stored signed
;; refund-query response against the durable binding.
(define (verify-alipay-refund! verifier record)
  (define event (journal-record-event record))
  (define sequence (journal-record-sequence record))
  (define pem
    (issuance-evidence-verifier-alipay-public-key-pem verifier))
  (unless (string? pem)
    (raise-commerce
     'evidence-verifier-unconfigured
     "no trusted Alipay public key is configured for evidence re-verification"
     (hash 'sequence sequence)))
  (define event-id (payment-event-event-id event))
  (unless (and (string-prefix? event-id "refund:")
               (> (string-length event-id) (string-length "refund:")))
    (raise-commerce
     'evidence-field-mismatch
     "refund event id does not carry the refund request id"
     (hash 'field 'event-id
           'sequence sequence)))
  (define request-id (substring event-id (string-length "refund:")))
  ;; The binding check runs first so a forged redirect row is refused on the
  ;; subject before any cryptographic work on attacker-chosen fields.
  (verify-binding! verifier record (payment-event-amount event))
  (define binding
    ((issuance-evidence-verifier-binding-lookup verifier)
     (payment-event-order-id event)))
  ;; The refund-query verification only reads order-id and amount from the
  ;; binding; app-id and seller-id are not durably stored and take the row's
  ;; provider/product identifiers as non-blank values that are never compared.
  (define signed-binding
    (alipay-binding
     (checkout-binding-provider binding)
     (checkout-binding-product-id binding)
     (checkout-binding-merchant-external-id binding)
     (checkout-binding-offer-id binding)
     (checkout-binding-subject-id binding)
     (money (checkout-binding-currency binding)
            (checkout-binding-amount-minor-units binding))))
  (define proof
    (verify-alipay-full-refund-query-response
     (journal-record-payload record) pem signed-binding request-id))
  (unless (string=? (alipay-full-refund-proof-order-id proof)
                    (payment-event-order-id event))
    (raise-commerce
     'evidence-field-mismatch
     "verified refund proof order does not match the journal row"
     (hash 'field 'order-id
           'sequence sequence)))
  (unless (= (alipay-full-refund-proof-amount proof)
             (money-minor-units (payment-event-amount event)))
    (raise-commerce
     'evidence-field-mismatch
     "verified refund proof amount does not match the journal row"
     (hash 'field 'amount
           'sequence sequence)))
  (unless (equal? (alipay-full-refund-proof-refunded-at proof)
                  (payment-event-occurred-at event))
    (raise-commerce
     'evidence-field-mismatch
     "verified refund settlement time does not match the journal row"
     (hash 'field 'occurred-at
           'sequence sequence))))

;; Re-authenticates one journaled payment or refund row against the claimed
;; outbox intent. Raises typed commerce errors on every failure mode; the
;; caller decides the release code from the error code, so every refusal is
;; deterministic and auditable.
(define (verify-issuance-evidence! verifier record claimed-offer-id
                                   claimed-subject-id)
  (unless (issuance-evidence-verifier? verifier)
    (raise-argument-error
     'verify-issuance-evidence! "issuance-evidence-verifier?" verifier))
  (unless (journal-record? record)
    (raise-argument-error
     'verify-issuance-evidence! "journal-record?" record))
  (unless (stable-id? claimed-offer-id)
    (raise-argument-error
     'verify-issuance-evidence! "stable kebab-case offer identifier"
     claimed-offer-id))
  (unless (opaque-id? claimed-subject-id)
    (raise-argument-error
     'verify-issuance-evidence! "non-empty opaque subject identifier"
     claimed-subject-id))
  (define event (journal-record-event record))
  (define payload (journal-record-payload record))
  (verify-catalog-and-claim! verifier record claimed-offer-id
                             claimed-subject-id)
  (cond
    [(and (string=? (payment-event-provider event) "alipay")
          (eq? (payment-event-kind event) 'payment-succeeded))
     (define pem
       (issuance-evidence-verifier-alipay-public-key-pem verifier))
     (unless (string? pem)
       (raise-commerce
        'evidence-verifier-unconfigured
        "no trusted Alipay public key is configured for evidence re-verification"
        (hash 'sequence (journal-record-sequence record))))
     (define notice
       (verify-alipay-notification
        (parse-alipay-form payload) pem))
     (alipay-notification-matches! notice record)
     (verify-binding! verifier record (payment-event-amount event))]
    [(and (string=? (payment-event-provider event) "alipay")
          (eq? (payment-event-kind event) 'payment-refunded))
     (verify-alipay-refund! verifier record)]
    [(string=? (payment-event-provider event) "pancake")
     (unless (eq? (payment-event-kind event) 'payment-succeeded)
       (raise-commerce
        'evidence-kind-unsupported
        "no offline refund verification exists for Pancake rows"
        (hash 'kind (payment-event-kind event)
              'sequence (journal-record-sequence record))))
     (define raw-evidence (journal-record-evidence record))
     (unless (bytes? raw-evidence)
       (raise-commerce
        'evidence-unverifiable
        "Pancake journal row lacks the journaled signature evidence"
        (hash 'sequence (journal-record-sequence record))))
     (define-values (environment signature-header)
       (parse-pancake-evidence raw-evidence))
     (define webhook
       (verify-pancake-webhook-signature
        payload signature-header
        #:environment environment
        #:keyring
        (issuance-evidence-verifier-pancake-keyring verifier)))
     (pancake-webhook-matches! webhook record)
     (define lookup
       (issuance-evidence-verifier-binding-lookup verifier))
     (unless (procedure? lookup)
       (raise-commerce
        'evidence-verifier-unconfigured
        "no checkout binding lookup is configured for evidence re-verification"
        (hash 'sequence (journal-record-sequence record))))
     (define binding
       (lookup (hash-ref (pancake-webhook-data webhook) 'orderId)))
     (unless (checkout-binding? binding)
       (raise-commerce
        'evidence-binding-missing
        "verified Pancake webhook order has no durable checkout binding"
        (hash 'sequence (journal-record-sequence record))))
     (unless (and (string=? (checkout-binding-offer-id binding)
                            (payment-event-offer-id event))
                  (string=? (checkout-binding-subject-id binding)
                            (payment-event-subject-id event)))
       (raise-commerce
        'evidence-binding-mismatch
        "verified Pancake webhook disagrees with the durable checkout binding"
        (hash 'order-id (checkout-binding-merchant-external-id binding)
              'binding-offer (checkout-binding-offer-id binding)
              'binding-subject (checkout-binding-subject-id binding)
              'evidence-offer (payment-event-offer-id event)
              'evidence-subject (payment-event-subject-id event)
              'sequence (journal-record-sequence record))))]
    [else
     (raise-commerce
      'evidence-provider-unsupported
      "no offline evidence verification exists for this provider"
      (hash 'provider (payment-event-provider event)
            'sequence (journal-record-sequence record)))])
  'verified)
