#lang racket/base

;; Issuer-side re-verification of journaled payment evidence: the durable
;; verified-evidence boundary named by ADR-0020. A claimed outbox row may only
;; induce signing when the journal row it was projected from carries payment
;; bytes the issuer can re-authenticate offline with issuer-held *public*
;; keys, whose re-derived facts match the stored canonical event, and whose
;; amount equals the pinned catalog price of the claimed Offer. A compromised
;; HTTP edge that writes forged journal, outbox, or projection rows therefore
;; cannot obtain a credential without a genuinely provider-signed payment for
;; the exact amount.
;;
;; This module runs inside the issuer role. It consumes no merchant private
;; key, makes no network request, and never trusts the edge's derived fields
;; beyond comparing them against what the signed bytes and the pinned catalog
;; independently establish.
(provide issuance-evidence-verifier?
         make-issuance-evidence-verifier
         verify-issuance-evidence!)

(require json
         racket/match
         racket/string
         "alipay.rkt"
         "pancake.rkt"
         "permit.rkt"
         "private/journal-model.rkt"
         "private/model.rkt")

(define (raise-commerce code message [data (hash)])
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

;; Deliberately opaque: verifier configuration is deployment material and
;; must never leak through diagnostic printing.
(struct issuance-evidence-verifier (catalog alipay-public-key-pem
                                            pancake-keyring))

(define max-evidence-bytes 4096)

(define (make-issuance-evidence-verifier
         #:catalog catalog
         #:alipay-public-key-pem [alipay-public-key-pem #f]
         #:pancake-keyring [pancake-keyring default-pancake-webhook-keyring])
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
  (issuance-evidence-verifier
   catalog alipay-public-key-pem pancake-keyring))

;; Checks that hold for every provider. The pinned catalog Offer is the
;; issuer's amount trust anchor because the offer-to-subject binding is
;; written by the edge and cannot authenticate itself. The claimed outbox
;; offer must equal the journal event's offer, so retargeting a pending row
;; after projection cannot steer the price anchor away from the bytes.
(define (verify-catalog-price! verifier record claimed-offer-id)
  (define event (journal-record-event record))
  (define sequence (journal-record-sequence record))
  (unless (eq? (payment-event-kind event) 'payment-succeeded)
    (raise-commerce
     'evidence-kind-unsupported
     "evidence re-verification currently covers succeeded payment rows"
     (hash 'kind (payment-event-kind event)
           'sequence sequence)))
  (unless (string=? (payment-event-offer-id event) claimed-offer-id)
    (raise-commerce
     'evidence-field-mismatch
     "claimed outbox Offer does not match the journaled payment evidence"
     (hash 'field 'offer-id
           'journaled (payment-event-offer-id event)
           'claimed claimed-offer-id
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

;; The verifier keeps its configuration outside the call path so the same
;; procedure can be handed to workers without threading extra parameters.

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

;; Re-authenticates one journaled payment row against the claimed outbox
;; intent. Raises typed commerce errors on every failure mode; the caller
;; decides the release code from the error code, so every refusal is
;; deterministic and auditable.
(define (verify-issuance-evidence! verifier record claimed-offer-id)
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
  (define event (journal-record-event record))
  (define payload (journal-record-payload record))
  (verify-catalog-price! verifier record claimed-offer-id)
  (cond
    [(string=? (payment-event-provider event) "alipay")
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
     (alipay-notification-matches! notice record)]
    [(string=? (payment-event-provider event) "pancake")
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
     (pancake-webhook-matches! webhook record)]
    [else
     (raise-commerce
      'evidence-provider-unsupported
      "no offline evidence verification exists for this provider"
      (hash 'provider (payment-event-provider event)
            'sequence (journal-record-sequence record)))])
  'verified)
