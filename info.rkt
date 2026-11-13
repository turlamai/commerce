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
(define version "0.1")
(define pkg-authors '(turlamai))
(define license 'Apache-2.0)
(define raco-commands
  '(("commerce" "commerce/operator/cli.rkt"
     "Commerce operator tools (find, explain, redrive)" "50")))

;; `deploy/` holds the hosted service deployment units (Dockerfile, systemd),
;; not packaged library source (same discipline as permit's source-omit-files).
(define source-omit-files
  '("deploy"))
