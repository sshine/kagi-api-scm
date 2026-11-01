;;; Shared test-suite entry point.
;;;
;;; SRFI-64's stock runner reports failures but exits 0, so a failing suite looks green
;;; to `just test` and to CI. run-suite fixes that. It also prints only the failures,
;;; because a line per assertion buries the few lines that matter.

(define-module (harness)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-64)
  #:export (run-suite
            live-tests?
            json-equal?))

(define (live-tests?)
  "Live tests run only when asked. A normal run and the Nix sandbox have no key."
  (equal? (getenv "KAGI_LIVE") "1"))

(define (quiet-runner)
  (let ((runner (test-runner-simple)))
    (test-runner-on-test-end! runner
      (lambda (r)
        (case (test-result-kind r)
          ((fail xpass)
           (format #t "FAIL ~a:~a~%  form:     ~s~%  expected: ~s~%  actual:   ~s~%"
                   (or (test-result-ref r 'source-file) "?")
                   (or (test-result-ref r 'source-line) "?")
                   (test-result-ref r 'source-form)
                   (test-result-ref r 'expected-value)
                   (test-result-ref r 'actual-value)))
          (else #f))))
    (test-runner-on-group-begin! runner (lambda (r name count) #f))
    (test-runner-on-group-end! runner (lambda (r) #f))
    (test-runner-on-final! runner (lambda (r) #f))
    runner))

(define (run-suite name thunk)
  (let ((runner (quiet-runner)))
    (test-with-runner runner
      (test-begin name)
      (thunk)
      (test-end name))
    (let ((passed (test-runner-pass-count runner))
          (failed (+ (test-runner-fail-count runner)
                     (test-runner-xpass-count runner))))
      (format #t "~a: ~a passed, ~a failed~%" name passed failed)
      (exit (if (zero? failed) 0 1)))))

;;; guile-json decodes object keys as strings. It preserves key order when encoding and
;;; reverses it when decoding, so a value that has been through the wire compares unequal
;;; to itself under `equal?` even before the string keys are considered. Object keys are
;;; unordered in JSON, so the comparison, not the library, is what has to give.

(define (json-equal? a b)
  (cond
   ((and (vector? a) (vector? b))
    (and (= (vector-length a) (vector-length b))
         (let loop ((i 0))
           (or (= i (vector-length a))
               (and (json-equal? (vector-ref a i) (vector-ref b i))
                    (loop (+ i 1)))))))
   ((and (list? a) (list? b) (every pair? a) (every pair? b))
    (and (= (length a) (length b))
         (every (lambda (kv)
                  (let ((hit (assoc (car kv) b)))
                    (and hit (json-equal? (cdr kv) (cdr hit)))))
                a)))
   (else (equal? a b))))
