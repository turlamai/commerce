#lang racket/base

(require commerce
         commerce/journal
         commerce/operator/cli
         commerce/provider
         commerce/storage
         commerce/storage/sqlite
         file/sha1
         json
         rackunit
         racket/file
         racket/port)

(define (payload-digest payload)
  (bytes->hex-string (sha256-bytes payload)))

;; One unique directory per database so rapid calls never share a path.
(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "commerce-cli-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc (build-path directory "commerce.sqlite")))
    (lambda ()
      (delete-directory/files directory))))

;; Captures stdout and returns (values exit-code parsed-json).
(define (call-with-cli proc)
  (define output (open-output-bytes))
  (define code
    (parameterize ([current-output-port output])
      (proc)))
  (values code
          (string->jsexpr
           (bytes->string/utf-8 (get-output-bytes output)))))

(test-case "find and explain render redacted JSON for one order"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment bytes")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept!
      storage payload
      (make-verified-payment-event
       "mock" "evt_001" (payload-digest payload) 'payment-succeeded
       "ord_001" "taskly-pro-lifetime" "customer-001"
       (money "USD" 2900) 1792108800)
      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (storage-close storage)

     (define-values (_find-code found)
       (call-with-cli
        (lambda ()
          (run-commerce-cli!
           (vector "find" (path->string path) "pending")))))
     (check-true (list? found))
     (check-equal? (length found) 1)
     (define item (car found))
     (check-equal? (hash-ref item 'idempotency-key) "mock/ord_001/grant")
     (check-equal? (hash-ref item 'status) "pending")
     (check-equal? (hash-ref item 'last-error-code) 'null)

     (define-values (_explain-code explanation)
       (call-with-cli
        (lambda ()
          (run-commerce-cli!
           (vector "explain" (path->string path) "mock" "ord_001")))))
     (define order (hash-ref explanation 'order))
     (check-true (hash-ref order 'paid?))
     (check-equal? (length (hash-ref explanation 'events)) 1)
     (define event (car (hash-ref explanation 'events)))
     ;; Raw provider bytes never reach the CLI surface.
     (check-false
      (member (bytes->string/utf-8 payload) (hash-keys event)))
     (check-equal? (length (hash-ref explanation 'work)) 1)
     (check-equal? (length (hash-ref explanation 'credentials)) 1))))

(test-case "invalid CLI arguments fail with parseable JSON"
  (for ([arguments (in-list (list (vector)
                                  (vector "find" "unused.sqlite" "unsupported")))])
    (define-values (code result)
      (call-with-cli (lambda () (run-commerce-cli! arguments))))
    (check-equal? code 1)
    (check-equal? (hash-ref result 'error) "invalid-arguments")
    (check-true (string? (hash-ref result 'usage)))))

(test-case "operator commands refuse to create a missing service database"
  (call-with-temporary-database
   (lambda (path)
     (check-false (file-exists? path))
     (for ([arguments (in-list
                       (list (vector "find" (path->string path))
                             (vector "explain" (path->string path) "mock" "order")
                             (vector "redrive" (path->string path) "missing")))])
       (define-values (code result)
         (call-with-cli (lambda () (run-commerce-cli! arguments))))
       (check-equal? code 1)
       (check-equal? (hash-ref result 'error) "database-not-found")
       (check-false (file-exists? path))))))

(test-case "redrive reports success and typed refusal as exit data"
  (call-with-temporary-database
   (lambda (path)
     (define payload #"authenticated payment bytes")
     (define storage (open-sqlite-commerce-storage path))
     (journal-accept!
      storage payload
      (make-verified-payment-event
       "mock" "evt_001" (payload-digest payload) 'payment-succeeded
       "ord_001" "taskly-pro-lifetime" "customer-001"
       (money "USD" 2900) 1792108800)
      #:received-at 10)
     (storage-project-next! storage #:processed-at 11)
     (storage-close storage)

     (define-values (redrive-code result)
       (call-with-cli
        (lambda ()
          (run-commerce-cli!
           (vector "redrive" (path->string path)
                   "mock/ord_001/grant")))))
     (check-equal? redrive-code 0)
     (check-true (hash-ref result 'redriven))

     ;; Unknown work prints the typed refusal and reports a nonzero code.
     (define-values (refusal-code refusal)
       (call-with-cli
        (lambda ()
          (run-commerce-cli!
           (vector "redrive" (path->string path)
                   "mock/missing/grant")))))
     (check-equal? refusal-code 1)
     (check-false (hash-ref refusal 'redriven))
     (check-equal? (hash-ref refusal 'code) "unknown-issuance-work"))))

(test-case "doctor reports the schema version and an empty readiness snapshot"
  (call-with-temporary-database
   (lambda (path)
     (define storage (open-sqlite-commerce-storage path))
     (storage-close storage)
     (define-values (code report)
       (call-with-cli
        (lambda ()
          (run-commerce-cli! (vector "doctor" (path->string path))))))
     (check-equal? code 0)
     (check-true (hash-ref report 'ok))
     (check-equal? (hash-ref report 'schema-version) 8)
     (check-equal? (hash-ref report 'warnings) '())
     (check-equal? (hash-ref (hash-ref report 'journal) 'total) 0)
     (check-equal? (hash-ref (hash-ref report 'work) 'pending) 0))))
