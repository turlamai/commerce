#lang racket/base

;; raco dynamically requires its entrypoint, so execution belongs here rather
;; than at import time in the reusable CLI implementation.
(require "cli.rkt")
(exit (run-commerce-cli! (current-command-line-arguments)))
