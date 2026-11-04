#lang racket/base

(require rackunit racket/tcp racket/port
         commerce
         (submod commerce/alipay/client test))

;; Exercise http-easy's actual streaming response port over loopback. The
;; production gateway is deliberately not contacted by this test.
(define (with-response payload run)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_host port _remote _remote-port) (tcp-addresses listener #t))
  (define worker
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept listener))
       (dynamic-wind
        void
        (lambda ()
          (let loop ()
            (define line (read-line in 'any))
            (unless (or (eof-object? line) (equal? line "")) (loop)))
          (read-bytes 3 in)
          (fprintf out "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n" (bytes-length payload))
          (write-bytes payload out)
          (flush-output out))
        (lambda () (close-output-port out) (close-input-port in))))))
  (dynamic-wind
   void
   (lambda () (run (format "http://127.0.0.1:~a/" port)))
   (lambda () (tcp-close listener) (kill-thread worker))))

(test-case "default Alipay transport reads actual streamed HTTP response"
  (with-response
   #"synthetic-response"
   (lambda (url)
     (define-values (status body) (default-transport url #"a=1"))
     (check-equal? status 200)
     (check-equal? body #"synthetic-response"))))

(test-case "stream limit rejects an oversized response"
  (with-response
   (make-bytes 65537 65)
   (lambda (url)
     (check-exn
      (lambda (e) (and (exn:fail:commerce? e)
                       (eq? (exn:fail:commerce-code e) 'alipay-query-unavailable)))
      (lambda () (default-transport url #"a=1"))))))

(test-case "stalled streams time out without waiting for EOF"
  (define-values (in out) (make-pipe))
  (dynamic-wind
   void
   (lambda () (check-false (read-bounded-response in 0.05)))
   (lambda () (close-input-port in) (close-output-port out))))
