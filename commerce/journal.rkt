#lang racket/base

(provide
 journal-record?
 journal-record-sequence
 journal-record-event
 journal-record-payload
 journal-record-received-at
 journal-acceptance?
 journal-acceptance-disposition
 journal-acceptance-record
 journal-accept!
 journal-ref)

(require file/sha1
         "log.rkt"
         "private/journal-model.rkt"
         "private/model.rkt"
         "private/storage-model.rkt")

(define (raise-commerce code message data)
  (raise
   (exn:fail:commerce
    message
    (current-continuation-marks)
    code
    data)))

(define (check-storage who storage)
  (unless (commerce-storage? storage)
    (raise-argument-error who "commerce-storage?" storage)))

;; A provider adapter may request acknowledgement only through this operation.
;; The raw bytes are copied before hashing so caller mutation cannot make the
;; digest check and the committed value disagree. Evidence carries the
;; supplementary provider-signed material (such as a webhook signature header)
;; the issuer role needs to re-verify the row offline; it is #f when the
;; payload itself is self-authenticating.
(define (journal-accept! storage payload event
                         #:received-at received-at
                         #:evidence [evidence #f])
  (check-storage 'journal-accept! storage)
  (unless (bytes? payload)
    (raise-argument-error 'journal-accept! "bytes?" payload))
  (unless (payment-event? event)
    (raise-argument-error 'journal-accept! "payment-event?" event))
  (unless (exact-nonnegative-integer? received-at)
    (raise-argument-error
     'journal-accept! "exact-nonnegative-integer?" received-at))
  (unless (or (not evidence) (bytes? evidence))
    (raise-argument-error 'journal-accept! "(or/c #f bytes?)" evidence))
  (define immutable-payload (bytes->immutable-bytes payload))
  (define immutable-evidence
    (and evidence (bytes->immutable-bytes evidence)))
  (define actual-digest
    (bytes->hex-string (sha256-bytes immutable-payload)))
  (unless (string=? actual-digest (payment-event-payload-digest event))
    (raise-commerce
     'payload-digest-mismatch
     "authenticated raw payload does not match the canonical event digest"
     (hash 'provider (payment-event-provider event)
           'event-id (payment-event-event-id event)
           'expected (payment-event-payload-digest event)
           'actual actual-digest)))
  (define result
    (with-handlers
        ([exn:fail:commerce?
          (lambda (failure)
            (when (eq? (exn:fail:commerce-code failure) 'event-conflict)
              (log-commerce-event!
               'warning 'journal-conflict
               (hash 'provider (payment-event-provider event)
                     'event-id (payment-event-event-id event)
                     'order-id (payment-event-order-id event))
               (hash)))
            (raise failure))])
      ((commerce-storage-journal-accept storage)
       immutable-payload event received-at immutable-evidence)))
  (define disposition (journal-acceptance-disposition result))
  (log-commerce-event!
   (if (eq? disposition 'accepted) 'info 'debug)
   (if (eq? disposition 'accepted) 'journal-accepted 'journal-replayed)
   (hash 'provider (payment-event-provider event)
         'event-id (payment-event-event-id event)
         'order-id (payment-event-order-id event))
   (hash 'kind (payment-event-kind event)
         'sequence
         (journal-record-sequence (journal-acceptance-record result))))
  result)

(define (journal-ref storage provider event-id)
  (check-storage 'journal-ref storage)
  (unless (stable-id? provider)
    (raise-argument-error
     'journal-ref "stable kebab-case provider identifier" provider))
  (unless (opaque-id? event-id)
    (raise-argument-error
     'journal-ref "non-empty opaque provider event identifier" event-id))
  ((commerce-storage-journal-lookup storage) provider event-id))
