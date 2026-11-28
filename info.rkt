#lang info

(define name "commerce")

(define collection 'multi)
(define deps
  '(["base" #:version "9.0"]
    "base64-lib"
    "crypto-lib"
    "db-lib"
    "http-easy-lib"
    "web-server-lib"
    ["permit" #:version "0.2.1"]))
(define build-deps '("rackunit-lib" "racket-doc" "scribble-lib"))
(define pkg-desc
  "Provider-neutral commerce orchestration for independent software")
(define version "0.1.4")
(define pkg-authors '(turlamai))
(define license 'Apache-2.0)



;; Deployment references and review governance are part of the installed source
;; documentation. Keep them when Racket prunes .git-prefixed paths by default.
(define source-keep-files '("deploy" ".github/PULL_REQUEST_TEMPLATE.md"))
