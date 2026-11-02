#lang racket/base

(require rackunit
         json
         racket/file
         commerce/hosted-registry)

(define (with-registry-files proc)
  (define dir (make-temporary-file "commerce-registry-~a" 'directory))
  (dynamic-wind void (lambda () (proc dir))
                (lambda () (delete-directory/files dir))))

(define (write-bytes-file path value)
  (call-with-output-file path
    (lambda (port) (write-bytes value port))
    #:exists 'truncate/replace))

(define (make-service key-path
                      #:id [service "publy-backend"]
                      #:subject [subject "account-a"]
                      #:product [product "publy"])
  (hasheq 'id service
          'key_file (path->string key-path)
          'scopes
          (list
           (hasheq 'issuer "com.turinglambdaai"
                   'subject_type "account"
                   'subject_id subject
                   'offer_id "publy-pro"
                   'product_id product))))

(define (write-registry path services)
  (write-bytes-file
   path (jsexpr->bytes (hasheq 'version 1 'services services))))

(test-case "registry keys are file-backed and access is exact account scope"
  (with-registry-files
   (lambda (dir)
     (define key-file (build-path dir "publy.key"))
     (define config (build-path dir "registry.json"))
     (write-bytes-file key-file (make-bytes 32 44))
     (write-registry config (list (make-service key-file)))
     (let ([registry (read-hosted-service-registry config)])
       (define (allow id subject offer product)
         (hosted-service-registry-allow-scope
          registry id "com.turinglambdaai" "account"
          subject offer product))
       (check-equal?
        (hosted-service-registry-resolve-key registry "publy-backend")
        (make-bytes 32 44))
       (check-false
        (hosted-service-registry-resolve-key registry "unknown"))
       (check-true (allow "publy-backend" "account-a" "publy-pro" "publy"))
       (check-false (allow "publy-backend" "account-b" "publy-pro" "publy"))
       (check-false (allow "publy-backend" "account-a" "publy-pro" "taskly"))
       (check-false (allow "publy-backend" "account-a" "other-offer" "publy"))
       (check-false (allow "other-service" "account-a" "publy-pro" "publy"))))))

(test-case "duplicate service IDs and inline keys are rejected"
  (with-registry-files
   (lambda (dir)
     (define key-file (build-path dir "secret.key"))
     (define config (build-path dir "registry.json"))
     (write-bytes-file key-file (make-bytes 32 20))
     (write-registry config (list (make-service key-file)
                                  (make-service key-file)))
     (check-exn exn:fail?
                (lambda () (read-hosted-service-registry config)))
     (write-registry
      config (list (hash-set (make-service key-file) 'key (make-string 64 #\a))))
     (check-exn exn:fail?
                (lambda () (read-hosted-service-registry config))))))

(test-case "invalid or missing secret files fail closed"
  (with-registry-files
   (lambda (dir)
     (define key-file (build-path dir "secret.key"))
     (define config (build-path dir "registry.json"))
     (write-bytes-file key-file (make-bytes 31 20))
     (write-registry config (list (make-service key-file)))
     (check-exn exn:fail?
                (lambda () (read-hosted-service-registry config)))
     (delete-file key-file)
     (check-exn exn:fail?
                (lambda () (read-hosted-service-registry config))))))

(test-case "malformed or duplicate-key JSON is never a service registry"
  (with-registry-files
   (lambda (dir)
     (define config (build-path dir "registry.json"))
     (write-bytes-file
      config #"{\"version\":1,\"version\":1,\"services\":[]}")
     (check-exn exn:fail?
                (lambda () (read-hosted-service-registry config)))
     (write-bytes-file config #"{\"version\":1,\"services\":[]}")
     (check-exn exn:fail?
                (lambda () (read-hosted-service-registry config))))))
