#lang racket/base

;; Durable, multi-process nonce admission for the hosted S2S MAC verifier.
;; Use an edge-only database file and user; never share an issuer private key.
(provide initialize-sqlite-hosted-replay-store!
         make-sqlite-hosted-replay-claimer)

(require db)

(define (connection-at path mode)
  (sqlite3-connect #:database path
                   #:mode mode
                   #:busy-retry-delay 0.05
                   #:busy-retry-limit 40))

(define (with-connection path callback #:mode [mode 'read/write])
  (define connection (connection-at path mode))
  (dynamic-wind void (lambda () (callback connection))
                (lambda () (disconnect connection))))

;; Provisioning is deliberately separate from runtime opening: a missing
;; database after a crash must be an error, never an empty replay history.
(define (initialize-sqlite-hosted-replay-store! database-path)
  (unless (path-string? database-path)
    (raise-argument-error 'initialize-sqlite-hosted-replay-store!
                          "path-string?" database-path))
  (with-connection
   database-path
   (lambda (connection)
     (query-exec
      connection
      "CREATE TABLE IF NOT EXISTS hosted_service_nonce (
         service_id TEXT NOT NULL CHECK (length(service_id) BETWEEN 1 AND 256),
         nonce TEXT NOT NULL CHECK (length(nonce) BETWEEN 16 AND 128),
         expires_at INTEGER NOT NULL CHECK (expires_at >= 0),
         PRIMARY KEY (service_id, nonce)
       )")
     (query-exec
      connection
      "CREATE INDEX IF NOT EXISTS hosted_service_nonce_expiry
       ON hosted_service_nonce(expires_at)"))
   #:mode 'create)
  (void))

(define (make-sqlite-hosted-replay-claimer database-path
                                         #:now [clock current-seconds])
  (unless (path-string? database-path)
    (raise-argument-error 'make-sqlite-hosted-replay-claimer
                          "path-string?" database-path))
  (unless (and (procedure? clock)
               (procedure-arity-includes? clock 0))
    (raise-argument-error 'make-sqlite-hosted-replay-claimer
                          "zero-argument trusted clock" clock))
  ;; Refuse missing or corrupted storage on start; runtime claims also use
  ;; read/write mode and fail closed on any later database disappearance.
  (with-connection
   database-path
   (lambda (connection)
     (unless (= 1 (query-value
                   connection
                   "SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'hosted_service_nonce'"))
       (error 'make-sqlite-hosted-replay-claimer
              "nonce replay table is not provisioned"))))
  ;; Return exactly #t for one atomic, durable first claim. SQLITE's UNIQUE
  ;; constraint serializes races between independent processes. Every claim
  ;; gets its own connection, so callbacks are safe across Racket threads.
  (lambda (service-id nonce expires-at)
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define now (clock))
      (and (exact-nonnegative-integer? now)
           (string? service-id)
           (<= 1 (string-length service-id) 256)
           (string? nonce)
           (<= 16 (string-length nonce) 128)
           (exact-nonnegative-integer? expires-at)
           (> expires-at now)
           (with-connection
            database-path
            (lambda (connection)
              (call-with-transaction
               connection
               (lambda ()
                 ;; Expired nonces may be deleted only after their entire MAC
                 ;; timestamp window has elapsed. The verifier must reject
                 ;; stale timestamps independently of this database cleanup.
                 (query-exec
                  connection
                  "DELETE FROM hosted_service_nonce WHERE expires_at <= ?"
                  now)
                 (query-exec
                  connection
                  "INSERT OR IGNORE INTO hosted_service_nonce
                   (service_id, nonce, expires_at) VALUES (?, ?, ?)"
                  service-id nonce expires-at)
                 (= 1 (query-value connection "SELECT changes()")))
               #:option 'immediate)))))))
