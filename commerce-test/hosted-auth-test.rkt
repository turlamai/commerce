#lang racket/base
(require rackunit
         commerce/hosted-auth)

(define service-key (make-bytes 32 77))
(define other-key (make-bytes 32 42))

(define (sign #:key [key service-key]
              #:nonce [nonce "fresh_nonce_value_001"]
              #:path [path "/v1/entitlement"]
              #:body [body #"{\"subject\":\"customer-a\"}"]
              #:subject [subject "customer-a"]
              #:product [product "taskly"]
              #:timestamp [timestamp 1000])
  (hosted-request-mac
   key #:service-id "publy-backend"
   #:method "POST" #:path path
   #:timestamp timestamp #:nonce nonce
   #:issuer "com.turinglambdaai"
   #:subject-type "account" #:subject-id subject
   #:offer-id "taskly-pro-lifetime" #:product-id product
   #:body body))

(define (verify #:key [key service-key]
                #:mac [mac (sign)]
                #:nonce [nonce "fresh_nonce_value_001"]
                #:path [path "/v1/entitlement"]
                #:body [body #"{\"subject\":\"customer-a\"}"]
                #:subject [subject "customer-a"]
                #:product [product "taskly"]
                #:timestamp [timestamp 1000]
                #:now [now 1000]
                #:resolver [resolver (lambda (_id) key)]
                #:authorizer
                [authorizer
                 (lambda (id issuer type subj offer prod)
                   (and (equal? id "publy-backend")
                        (equal? issuer "com.turinglambdaai")
                        (equal? type "account")
                        (equal? subj "customer-a")
                        (equal? offer "taskly-pro-lifetime")
                        (equal? prod "taskly")))]
                #:claim [claim (lambda (_id _nonce _expires) #t)])
  (verify-hosted-service-request
   #:service-id "publy-backend" #:method "POST" #:path path
   #:timestamp timestamp #:nonce nonce
   #:issuer "com.turinglambdaai" #:subject-type "account"
   #:subject-id subject #:offer-id "taskly-pro-lifetime"
   #:product-id product #:body body #:mac mac
   #:resolve-key resolver #:allow-scope authorizer
   #:claim-once! claim #:now now))

(test-case "the same signed scope succeeds exactly once"
  (define seen (make-hash))
  (define (claim id nonce expires)
    (define key (cons id nonce))
    (if (hash-has-key? seen key)
        #f
        (begin (hash-set! seen key expires) #t)))
  (check-true (verify #:claim claim))
  (check-equal? (hash-ref seen (cons "publy-backend" "fresh_nonce_value_001"))
                1301)
  (check-false (verify #:claim claim))
  (check-equal? (hash-count seen) 1))

(test-case "MAC is bound to method, route, body, subject and product"
  (check-false (verify #:body #"changed"))
  (check-false (verify #:path "/v1/other"))
  (check-false (verify #:subject "customer-b"))
  (check-false (verify #:product "movebit"))
  (check-false (verify #:key other-key))
  (check-false (verify #:mac (make-bytes 31 0)))
  (check-false (verify #:mac (make-bytes 32 0)))
  (check-false (verify #:resolver (lambda (_id) #f)))
  (check-false (verify #:resolver (lambda (_id) #"short-key")))
  ;; No collision from a colon or newline in the signed resource.
  (check-false
   (bytes=? (sign #:path "/v1:a")
            (sign #:path "/v1\na"))))

(test-case "properly signed cross-product and cross-account requests still deny"
  (check-false
   (verify #:product "movebit" #:mac (sign #:product "movebit")))
  (check-false
   (verify #:subject "customer-b" #:mac (sign #:subject "customer-b")))
  (check-false
   (verify #:authorizer (lambda args 'yes)))
  (check-false
   (verify #:claim (lambda args 'yes))))

(test-case "clock skew and missing replay storage fail closed"
  (check-true (verify #:now 1300))
  (check-true (verify #:now 700))
  (check-false (verify #:now 1301))
  (check-false (verify #:now 699))
  (check-false (verify #:claim
                       (lambda (_id _nonce _expires)
                         (error 'replay-db "unavailable"))))
  (check-false (verify #:resolver (lambda (_) (error 'registry "offline"))))
  (check-false (verify #:nonce "tiny"))
  (check-false (verify #:timestamp -1))
  (check-exn exn:fail?
             (lambda () (sign #:key #"weak"))))

(test-case "valid MAC and scope cannot bypass failed atomic replay admission"
  (define replay-calls 0)
  (check-false
   (verify #:claim (lambda (_id _nonce _expiry)
                     (set! replay-calls (add1 replay-calls))
                     #f)))
  (check-equal? replay-calls 1)
  (set! replay-calls 0)
  (check-false
   (verify #:mac (make-bytes 32 0)
           #:claim (lambda args (set! replay-calls (add1 replay-calls)) #t)))
  (check-equal? replay-calls 0))
