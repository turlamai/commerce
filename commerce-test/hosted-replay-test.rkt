#lang racket/base
(require rackunit
         racket/file
         commerce/hosted-replay/sqlite)

(test-case "durable nonce claims survive reopen and are scoped per service"
  (define dir (make-temporary-file "commerce-s2s-nonce-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define db-path (build-path dir "replay.sqlite"))
     (define first
       (begin
         (initialize-sqlite-hosted-replay-store! db-path)
         (make-sqlite-hosted-replay-claimer db-path #:now (lambda () 1000))))
     ;; A second closure uses a separate connection for each claim.
     (define second
       (make-sqlite-hosted-replay-claimer db-path #:now (lambda () 1000)))
     (check-true (first "publy-backend" "nonce_unique_123456" 1301))
     (check-false (first "publy-backend" "nonce_unique_123456" 1301))
     ;; Reopening simulates a restarted edge process.
     (check-false (second "publy-backend" "nonce_unique_123456" 1301))
     (check-true (second "movebit-backend" "nonce_unique_123456" 1301))
     (check-false (second "movebit-backend" "nonce_unique_123456" 1301))
     (check-false (second "publy-backend" "short" 1301))
     (check-false (second "publy-backend" "another_nonce_12345" 999)))
   (lambda () (delete-directory/files dir))))

(test-case "nonce cleanup never allows replay inside the original MAC window"
  (define dir (make-temporary-file "commerce-s2s-ttl-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define path (build-path dir "nonces.sqlite"))
     (define at-early
       (begin
         (initialize-sqlite-hosted-replay-store! path)
         (make-sqlite-hosted-replay-claimer path #:now (lambda () 1299))))
     (define at-expiry
       (make-sqlite-hosted-replay-claimer path #:now (lambda () 1301)))
     (check-true (at-early "publy" "fresh_nonce_value_001" 1301))
     (check-false (at-early "publy" "fresh_nonce_value_001" 1301))
     ;; After expiry the row may be garbage-collected, but this callback
     ;; must still refuse a claim whose stated expiry has already passed.
     (check-false (at-expiry "publy" "fresh_nonce_value_001" 1301))
     (check-true (at-expiry "publy" "another_nonce_value_002" 1602)))
   (lambda () (delete-directory/files dir))))

(test-case "replay database failure rejects rather than authorizing"
  (define dir (make-temporary-file "commerce-s2s-fail-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define path (build-path dir "nonces.sqlite"))
     (define claim (begin
                     (initialize-sqlite-hosted-replay-store! path)
                     (make-sqlite-hosted-replay-claimer
                      path #:now (lambda () 1000))))
     (check-true (claim "publy" "nonce_initial_12345" 1301))
     ;; A vanished live database must never silently recreate an empty store:
     ;; that would permit replay while the signed timestamp is still valid.
     (delete-file path)
     (check-false (claim "publy" "nonce_after_failure" 1301))
     (check-exn
      exn:fail?
      (lambda ()
        (make-sqlite-hosted-replay-claimer path
                                           #:now (lambda () 1000)))))
   (lambda ()
     (when (directory-exists? dir)
       (delete-directory/files dir)))))
