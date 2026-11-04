#lang racket/base

(provide read-bounded-stream)

;; Some HTTP response ports wrap a pipe without compatible progress events.
;; A cancellable reader preserves the size bound and deadline without using
;; read-bytes-evt on those wrapped ports. The caller remains responsible for
;; closing the input and rejecting EOF, failures and oversize results.
(define (read-bounded-stream input max-bytes timeout-seconds)
  (define result (make-channel))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (_) (channel-put result #f))])
         (channel-put result (read-bytes (add1 max-bytes) input))))))
  (dynamic-wind
    void
    (lambda () (sync/timeout timeout-seconds result))
    (lambda () (kill-thread worker))))
