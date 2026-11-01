;;; Runs every tests/*-test.scm in its own process.
;;;
;;; A separate process per suite because a suite may set global state and one suite must
;;; not be able to decide another one's outcome. The runner also gives each one a fresh
;;; auto-compile cache, so a stale entry in the developer's home cannot print a note for
;;; every module.

(use-modules (ice-9 ftw)
             (ice-9 popen)
             (ice-9 rdelim)
             (srfi srfi-1))

;; (current-filename) is #f under `guile -s`, so take the path we were invoked with.
(define test-dir
  (canonicalize-path (dirname (or (current-filename) (car (command-line))))))

(define cache-dir
  (let loop ((n 0))
    (let ((dir (string-append (or (getenv "TMPDIR") "/tmp")
                              "/kagi-test-cache-"
                              (number->string (getpid))
                              "-"
                              (number->string n))))
      (if (file-exists? dir)
          (loop (+ n 1))
          (begin (mkdir dir #o700) dir)))))

(define (requested-suite)
  (let ((args (cdr (command-line))))
    (and (pair? args) (not (string-null? (car args))) (car args))))

(define (suite-files)
  (let ((requested (requested-suite)))
    (if requested
        (list (if (string-suffix? "-test.scm" requested)
                  requested
                  (string-append requested "-test.scm")))
        (sort (filter (lambda (f) (string-suffix? "-test.scm" f))
                      (or (scandir test-dir) '()))
              string<?))))

(define (src-dir)
  (string-append (dirname test-dir) "/src"))

(define (run-one file)
  (let* ((path (string-append test-dir "/" file))
         (status (status:exit-val
                  (system* "env" (string-append "XDG_CACHE_HOME=" cache-dir)
                           "guile" "--no-auto-compile"
                           "-L" (src-dir) "-L" test-dir
                           "-s" path))))
    (format #t "~a ~a~%" (if (eqv? status 0) "  ok" "FAIL") file)
    (eqv? status 0)))

(let* ((files (suite-files))
       (results (map run-one files))
       (failed (length (filter not results))))
  (false-if-exception (system* "rm" "-rf" cache-dir))
  (newline)
  (format #t "~a suite(s), ~a failed~%" (length files) failed)
  (exit (if (zero? failed) 0 1)))
