#lang racket/base
;; Rebuild immutable per-order periods from the authenticated scoped journal.
(provide prepaid-period-end)
(require racket/list "model.rkt" "journal-model.rkt" "projection.rkt" "time.rkt")
(define (refuse code)
  (raise (exn:fail:commerce "Prepaid period reconciliation refused"
                          (current-continuation-marks) code (hash))))
(define (prepaid-period-end records months expected-offer subject amount)
  (define orders
    (for/fold ([orders (hash)]) ([record (in-list records)])
      (define event (journal-record-event record))
      (unless (and (equal? (payment-event-offer-id event) expected-offer)
                   (equal? (payment-event-subject-id event) subject)
                   (equal? (payment-event-amount event) amount)
                   (not (payment-event-paid-through event)))
        (refuse 'prepaid-evidence-conflict))
      (define key (cons (payment-event-provider event) (payment-event-order-id event)))
      (define previous (hash-ref orders key #f))
      (when (and previous (order-projection-paid? previous)
                 (eq? (payment-event-kind event) 'payment-succeeded)
                 (not (= (order-projection-paid-at previous)
                         (payment-event-occurred-at event))))
        (refuse 'prepaid-evidence-conflict))
      (define-values (next _intents)
        (project-order-event previous event))
      (hash-set orders key next)))
  (define ends
    (for/list ([order (in-hash-values orders)]
               #:when (and (order-projection-paid? order)
                           (not (order-projection-refunded? order))))
      (with-handlers ([exn:fail? (lambda (_) (refuse 'invalid-entitlement-request))])
        (epoch-seconds+calendar-months->rfc3339
         (order-projection-paid-at order) months))))
  (and (pair? ends) (car (sort ends string>?))))
