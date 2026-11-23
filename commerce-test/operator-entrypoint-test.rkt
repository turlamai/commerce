#lang racket/base
(require rackunit racket/runtime-path setup/getinfo commerce/operator/cli)
(define-runtime-path collection "../commerce")
(define metadata (get-info/full collection))
(check-not-false metadata "The installed collection must register the raco entrypoint")
(when metadata
 (check-equal? (metadata 'raco-commands (lambda () #f))
  '(("commerce" commerce/operator/raco "Commerce operator tools" 50))))
(define out (open-output-string))
(check-equal? (parameterize ([current-output-port out]) (run-commerce-cli! #("--help"))) 0)
(check-regexp-match #rx"raco commerce nowpay" (get-output-string out))
