(use-modules (srfi srfi-64)
             (harness)
             (kagi api)
             (fake-kagi)
             (json))

(define (search-body)
  "{\"meta\":{\"trace\":\"trace-abc\",\"node\":\"us-central1\",\"ms\":42},
    \"data\":{\"search\":[{\"url\":\"https://a\",\"title\":\"A\",\"snippet\":\"s\"}]}}")

(define (error-body code message)
  (format #f
          "{\"meta\":{\"trace\":\"trace-error\"},\"data\":null,\"errors\":[{\"code\":\"~a\",\"url\":\"https://help\",\"message\":\"~a\",\"location\":null}]}"
          code message))

(define (retry-after-body seconds)
  `((status . 429)
    (content-type . "application/json")
    (headers . (("retry-after" . ,(number->string seconds))))
    (body . ,(error-body "429" "Rate limited"))))

(define (raises? thunk pred)
  (catch 'kagi-error
    (lambda () (thunk) #f)
    (lambda (key err) (pred err))))

(run-suite
 "http"
 (lambda ()
   (test-group "a search sends the bearer token and the documented body"
     (with-fake-kagi
      (list (json-response (search-body)))
      (lambda (base)
        (let* ((client (make-client "KG_test" #:base-url base #:max-retries 0))
               (output (client-search client (make-search-request "steve jobs")))
               (request (last-request)))
          (test-assert (search-output-json? output))
          (test-equal "trace-abc"
                      (search-response-trace (search-output->json output)))
          (test-equal "POST" (request-method request))
          (test-equal "/search" (request-path request))
          (test-equal "Bearer KG_test" (request-header request "authorization"))
          (test-equal "application/json"
                      (car (string-split (request-header request "content-type")
                                         #\;)))
          (test-assert (json-equal? (json-string->scm (request-body request))
                                    '(("query" . "steve jobs"))))
          (test-equal 1 (client-requests-made client))))))

   (test-group "a base URL with a trailing slash does not double it"
     (with-fake-kagi
      (list (json-response (search-body)))
      (lambda (base)
        (let* ((client (make-client "KG_test"
                                    #:base-url (string-append base "/")
                                    #:max-retries 0)))
          (client-search client (make-search-request "q"))
          (test-equal "/search" (request-path (last-request)))))))

   (test-group "a markdown response keeps its trace"
     (with-fake-kagi
      (list (markdown-response "# Results" #:trace "trace-md"))
      (lambda (base)
        (let* ((client (make-client "KG_test" #:base-url base #:max-retries 0))
               (output (client-search client
                                      (make-search-request "q" #:format 'markdown))))
          (test-assert (search-output-markdown? output))
          (test-equal "# Results" (search-output-markdown output))
          (test-equal "trace-md" (search-output-trace output))))))

   (test-group "a 401 is unauthorized with the server's code"
     (with-fake-kagi
      (list (json-response (error-body "2" "Unauthorized") #:status 401))
      (lambda (base)
        (let ((client (make-client "KG_test" #:base-url base #:max-retries 0)))
          (test-assert
           (raises? (lambda () (client-search client (make-search-request "q")))
                    (lambda (err)
                      (and (unauthorized-error? err)
                           (equal? "2" (api-error-code (kagi-error-body err)))
                           (equal? "Unauthorized"
                                   (api-error-message (kagi-error-body err)))))))))))

   (test-group "a 400 validation error keeps the location"
     (with-fake-kagi
      (list (json-response
             "{\"errors\":[{\"code\":\"search.invalid_parameter\",\"message\":\"bad\",\"location\":\"limit\"}]}"
             #:status 400))
      (lambda (base)
        (let ((client (make-client "KG_test" #:base-url base #:max-retries 0)))
          (test-assert
           (raises? (lambda () (client-search client (make-search-request "q")))
                    (lambda (err)
                      (and (validation-error? err)
                           (equal? "limit"
                                   (api-error-location (kagi-error-body err)))))))))))

   (test-group "a 429 honours Retry-After and replays"
     (with-fake-kagi
      (list (retry-after-body 0)
            (json-response (search-body)))
      (lambda (base)
        (let ((client (make-client "KG_test" #:base-url base #:max-retries 1)))
          (let ((output (client-search client (make-search-request "q"))))
            (test-assert (search-output-json? output))
            (test-equal 2 (client-requests-made client))
            (test-equal 2 (length (requests))))))))

   (test-group "a 500 is retried and then succeeds"
     (with-fake-kagi
      (list (json-response (error-body "500" "boom") #:status 500)
            (json-response (search-body)))
      (lambda (base)
        (let ((client (make-client "KG_test" #:base-url base
                                   #:max-retries 1
                                   #:initial-backoff 0.001)))
          (client-search client (make-search-request "q"))
          (test-equal 2 (client-requests-made client))))))

   (test-group "a 500 with no retries left is a server error"
     (with-fake-kagi
      (list (json-response (error-body "500" "boom") #:status 500))
      (lambda (base)
        (let ((client (make-client "KG_test" #:base-url base #:max-retries 0)))
          (test-assert
           (raises? (lambda () (client-search client (make-search-request "q")))
                    server-error?))))))

   (test-group "a throttle longer than the ceiling fails instead of sleeping"
     (with-fake-kagi
      (list (retry-after-body 60))
      (lambda (base)
        (let ((client (make-client "KG_test" #:base-url base
                                   #:max-retries 3
                                   #:max-retry-delay 1)))
          (test-assert
           (raises? (lambda () (client-search client (make-search-request "q")))
                    rate-limited?))
          (test-equal 1 (client-requests-made client))))))

   (test-group "a body that is not JSON is a decode error"
     (with-fake-kagi
      (list (json-response "not json at all"))
      (lambda (base)
        (let ((client (make-client "KG_test" #:base-url base #:max-retries 0)))
          (test-assert
           (raises? (lambda () (client-search client (make-search-request "q")))
                    decode-error?))))))

   (test-group "a transport failure is a transport error"
     ;; Port 1 is not listening, so the connection is refused before any HTTP exists.
     (let ((client (make-client "KG_test"
                                #:base-url "http://127.0.0.1:1"
                                #:max-retries 0)))
       (test-assert
        (raises? (lambda () (client-search client (make-search-request "q")))
                 transport-error?))))))
