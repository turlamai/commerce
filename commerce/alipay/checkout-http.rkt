#lang racket/base

;; Compatibility entry point for existing consumers. New integrations should
;; require commerce/alipay/page-pay-http; this shim shares the same bindings.
(require "page-pay-http.rkt")
(provide (all-from-out "page-pay-http.rkt"))
