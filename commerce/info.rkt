#lang info

;; Multi-collection packages register executable tools at collection scope.
(define raco-commands
  '(("commerce" commerce/operator/raco "Commerce operator tools" 50)))

;; This executable exits by design; the archive gate exercises it as a process.
(define test-omit-paths '("operator/raco.rkt"))
