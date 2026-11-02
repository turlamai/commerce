#lang racket/base

(provide
 (struct-out journal-record)
 (struct-out journal-acceptance))

;; A record is the exact durable input plus the canonical meaning established
;; by the provider adapter at acceptance time. Evidence carries the
;; supplementary provider-signed bytes (such as a webhook signature header)
;; that the edge used to authenticate the payload; it is #f when the payload
;; itself is self-authenticating.
(struct journal-record (sequence event payload received-at evidence)
  #:transparent)

;; disposition is either 'accepted for a new durable row or 'replayed for an
;; exact retry that resolved to the original row.
(struct journal-acceptance (disposition record) #:transparent)
