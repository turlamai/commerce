#lang racket/base

(require rackunit
         commerce/private/alipay-time)

(test-case "Alipay GMT+8 conversion is independent of host local time"
  (for ([entry (in-list
                '(("2000-01-01 08:00:00" . 946684800)
                  ("2024-02-29 00:00:00" . 1709136000)
                  ("2026-10-30 12:30:00" . 1793334600)
                  ("2026-10-30 13:45:00" . 1793339100)
                  ("2026-11-03 16:00:00" . 1793692800)))])
    (check-equal? (gmt8-wall-time->epoch (car entry)) (cdr entry))
    (check-equal? (epoch-seconds->gmt8-timestamp (cdr entry))
                  (car entry))))

(test-case "Alipay timestamps reject nonexistent dates and bad wall times"
  (for ([bad (in-list
              '("2026-02-29 00:00:00"
                "2026-04-31 12:00:00"
                "2100-02-29 00:00:00"
                "2026-00-01 00:00:00"
                "2026-13-01 00:00:00"
                "2026-10-30 24:00:00"
                "2026-10-30 00:60:00"
                "2026-10-30 00:00:60"
                "2026-10-30T12:30:00Z"
                "2026-10-30 12:30:00 "
                ""))])
    (check-exn exn:fail:contract?
               (lambda () (gmt8-wall-time->epoch bad))))
  (check-exn exn:fail:contract?
             (lambda () (gmt8-wall-time->epoch 123)))
  (check-exn exn:fail:contract?
             (lambda () (epoch-seconds->gmt8-timestamp -1))))
