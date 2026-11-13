#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path)

(define-runtime-path library "../commerce")

;; Inspect reader datums rather than comments; this is an API-tier guard,
;; independent of the behavioral JSON regressions in provider/HTTP tests.
(define (private-permit-reference? value)
  (cond
    [(symbol? value)
     (regexp-match? #rx"^permit/private(/|$)" (symbol->string value))]
    [(string? value)
     (regexp-match? #rx"^permit/private(/|$)" value)]
    [(pair? value)
     (or (private-permit-reference? (car value))
         (private-permit-reference? (cdr value)))]
    [else #f]))

(test-case "Commerce library uses only documented public Permit modules"
  (for ([path (in-directory library)]
        #:when (regexp-match? #rx"[.]rkt$" (path->string path)))
    (define form
      (call-with-input-file path
        (lambda (in)
          (parameterize ([read-accept-reader #t]) (read in)))))
    (check-false (private-permit-reference? form) (path->string path))))
