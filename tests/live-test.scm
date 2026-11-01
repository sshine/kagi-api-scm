(use-modules (srfi srfi-64)
             (srfi srfi-13)
             (harness)
             (kagi api))

(define (env name)
  (let ((value (getenv name)))
    (and value (not (string-null? (string-trim-both value))) value)))

(define (query)
  (or (env "KAGI_TEST_QUERY") "steve jobs"))

(if (not (live-tests?))
    (begin
      (display "KAGI_LIVE is not set; skipping the live suite\n")
      (exit 0))
    (let ((key (env "KAGI_API_KEY")))
      (if (not key)
          (begin
            (display "KAGI_API_KEY is not set; run this with `just live-test`\n"
                     (current-error-port))
            (exit 2))
          (run-suite
           "live"
           (lambda ()
             (test-group "a search returns results and a trace"
               (let* ((client (make-client key))
                      (request (make-search-request (query) #:limit 3))
                      (response (client-search-json client request))
                      (results (search-data-ref (search-response-data response)
                                                'search)))
                 (test-assert (string? (search-response-trace response)))
                 (test-assert (> (vector-length results) 0))
                 (test-assert (<= (vector-length results) 3))
                 (format #t "trace ~a: ~a result(s) across ~a categor(ies)~%"
                         (search-response-trace response)
                         (length (search-data-results (search-response-data response)))
                         (length (search-data-categories (search-response-data response))))))

             (test-group "markdown arrives as markdown"
               (let* ((client (make-client key))
                      (request (make-search-request (query)
                                                    #:limit 2
                                                    #:format 'markdown))
                      (output (client-search client request))
                      (markdown (search-output-markdown output)))
                 (test-assert (search-output-markdown? output))
                 (test-assert (string? markdown))
                 (test-assert (> (string-length (string-trim-both markdown)) 0))
                 (format #t "markdown: ~a byte(s)~%" (string-length markdown))))))))))
