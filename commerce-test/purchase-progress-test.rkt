#lang racket/base

(require rackunit
         racket/file
         racket/list
         crypto
         crypto/libcrypto
         commerce
         commerce/provider
         commerce/journal
         commerce/storage
         commerce/storage/sqlite
         commerce/purchase-progress)

(define (with-checkout proc)
  (define dir (make-temporary-file "commerce-progress-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define storage
       (open-sqlite-commerce-storage (build-path dir "commerce.sqlite")))
     (dynamic-wind
      void
      (lambda ()
        (storage-create-checkout-binding!
         storage
         (checkout-binding "synthetic-order" "mock"
                           "movebit" "movebit-pro-test-only"
                           "account-001" "CNY" 1234 2)
         #:created-at 1793692700)
        (proc storage))
      (lambda () (storage-close storage))))
   (lambda () (delete-directory/files dir))))

(define (allow _provider _order _product _offer subject)
  (equal? subject "account-001"))

(define (read-progress storage
                       #:provider [provider "mock"]
                       #:order [order "synthetic-order"]
                       #:product [product "movebit"]
                       #:offer [offer "movebit-pro-test-only"]
                       #:subject [subject "account-001"]
                       #:authorize [authorize allow])
  (current-purchase-progress
   storage #:provider provider #:order-id order
   #:product-id product #:offer-id offer
   #:subject-id subject #:authorize authorize))

(define (payment raw event-id kind)
  (make-verified-payment-event
   "mock" event-id (bytes->hex-string
   (parameterize ([crypto-factories (list libcrypto-factory)])
     (digest 'sha256 raw))) kind
   "synthetic-order" "movebit-pro-test-only" "account-001"
   (money "CNY" 1234) 1793692800))

(test-case "status stays nonauthoritative from pending to refund and replay"
  (with-checkout
   (lambda (storage)
     (check-equal? (read-progress storage)
                   (hasheq 'status "awaiting-payment"))
     (define paid #"synthetic-authenticated-paid")
     (define paid-event (payment paid "event-paid" 'payment-succeeded))
     (journal-accept! storage paid paid-event #:received-at 1793692801)
     (check-equal? (read-progress storage)
                   (hasheq 'status "payment-processing"))
     (storage-project-next! storage #:processed-at 1793692802)
     (check-equal? (read-progress storage)
                   (hasheq 'status "issuance-pending"))
     (check-eq?
      (journal-acceptance-disposition
       (journal-accept! storage paid paid-event #:received-at 1793692803))
      'replayed)
     (check-equal? (read-progress storage)
                   (hasheq 'status "issuance-pending"))
     (define refund #"synthetic-authenticated-refund")
     (journal-accept!
      storage refund (payment refund "event-refund" 'payment-refunded)
      #:received-at 1793692804)
     (check-equal? (read-progress storage)
                   (hasheq 'status "refund-pending"))
     (storage-project-next! storage #:processed-at 1793692805)
     (check-equal? (read-progress storage)
                   (hasheq 'status "refunded")))))

(test-case "subject/product/offer substitution fails before revealing an order"
  (with-checkout
   (lambda (storage)
     (check-exn
      exn:fail:commerce?
      (lambda () (read-progress storage #:subject "another-account")))
     (for ([kind (in-list '(product offer provider))])
       (check-exn
        exn:fail:commerce?
        (lambda ()
          (case kind
            [(product) (read-progress storage #:product "taskly")]
            [(offer) (read-progress storage #:offer "taskly-pro")]
            [(provider) (read-progress storage #:provider "alipay")]))))
     (check-equal? (read-progress storage #:order "not-a-real-order")
                   (hasheq 'status "unknown-checkout")))))

(test-case "even a signed workflow record never becomes a client paid flag"
  (with-checkout
   (lambda (storage)
     (define response (read-progress storage))
     (check-equal? (sort (hash-keys response) symbol<?) '(status))
     (check-false (hash-has-key? response 'paid))
     (check-false (hash-has-key? response 'claim_token))
     (check-false (hash-has-key? response 'customer_email)))))
