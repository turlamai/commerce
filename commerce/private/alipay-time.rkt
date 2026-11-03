#lang racket/base

;; Alipay public-key-mode timestamps are China Standard Time (UTC+08:00),
;; not the operating system's local time zone. Never call seconds->date or
;; find-seconds with the server's environment-dependent clock settings.
(provide gmt8-wall-time->epoch epoch-seconds->gmt8-timestamp)

(require "time.rkt")

(define offset-seconds (* 8 60 60))

(define (leap-year? year)
  (and (zero? (remainder year 4))
       (or (not (zero? (remainder year 100)))
           (zero? (remainder year 400)))))

(define (days-in-month year month)
  (case month
    [(1 3 5 7 8 10 12) 31]
    [(4 6 9 11) 30]
    [(2) (if (leap-year? year) 29 28)]
    [else 0]))

;; Inverse of the Gregorian civil-from-days algorithm in private/time.rkt.
;; The provider's documented 2000–2100 range keeps all divisions positive.
(define (days-from-civil year month day)
  (define y (if (<= month 2) (sub1 year) year))
  (define era (quotient y 400))
  (define year-of-era (- y (* era 400)))
  (define adjusted-month (+ month (if (> month 2) -3 9)))
  (define day-of-year
    (+ (quotient (+ (* 153 adjusted-month) 2) 5) (sub1 day)))
  (define day-of-era
    (+ (* year-of-era 365)
       (quotient year-of-era 4)
       (- (quotient year-of-era 100))
       day-of-year))
  (- (+ (* era 146097) day-of-era) 719468))

(define (gmt8-wall-time->epoch value)
  (define parts
    (and (string? value)
         (regexp-match
          #px"^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$"
          value)))
  (unless parts
    (raise-argument-error 'gmt8-wall-time->epoch
                          "Alipay GMT+8 timestamp (YYYY-MM-DD HH:MM:SS)"
                          value))
  (define-values (year month day hour minute second)
    (apply values (map string->number (cdr parts))))
  (unless (and (<= 2000 year 2100)
               (<= 1 month 12)
               (<= 1 day (days-in-month year month))
               (<= 0 hour 23) (<= 0 minute 59) (<= 0 second 59))
    (raise-argument-error 'gmt8-wall-time->epoch
                          "valid Gregorian Alipay GMT+8 timestamp"
                          value))
  (- (+ (* (days-from-civil year month day) 86400)
        (* hour 3600) (* minute 60) second)
     offset-seconds))

(define (epoch-seconds->gmt8-timestamp epoch)
  (unless (exact-nonnegative-integer? epoch)
    (raise-argument-error 'epoch-seconds->gmt8-timestamp
                          "exact-nonnegative-integer?" epoch))
  (define utc-spelling
    (epoch-seconds->rfc3339 (+ epoch offset-seconds)))
  (string-append (substring utc-spelling 0 10) " "
                 (substring utc-spelling 11 19)))
