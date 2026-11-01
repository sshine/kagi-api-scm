(use-modules (srfi srfi-64)
             (harness)
             (kagi api)
             (json))

(define (decode text)
  (json->search-response (json-string->scm text)))

(run-suite
 "response"
 (lambda ()
   (test-group "the named categories are separated"
     (let ((response
            (decode
             "{\"meta\":{\"trace\":\"abc\",\"node\":\"us-central1\",\"ms\":42},
               \"data\":{
                 \"search\":[{\"url\":\"https://a\",\"title\":\"A\",\"snippet\":\"one\",
                              \"props\":{\"language\":\"en\"}}],
                 \"news\":[{\"url\":\"https://b\",\"title\":\"B\"}],
                 \"image\":[{\"url\":\"https://c\",\"title\":\"C\",
                             \"image\":{\"url\":\"https://c.png\",\"width\":640,\"height\":480}}],
                 \"future_group\":[{\"anything\":true}]
               }}")))
       (test-equal "abc" (search-response-trace response))
       (let ((data (search-response-data response)))
         (test-equal '(search image news) (search-data-categories data))
         (test-equal 1 (vector-length (search-data-ref data 'search)))
         (test-equal "A" (search-result-title
                          (vector-ref (search-data-ref data 'search) 0)))
         (test-equal "en"
                     (assoc-ref
                      (search-result-props
                       (vector-ref (search-data-ref data 'search) 0))
                      "language"))
         (test-equal 640
                     (search-image-width
                      (search-result-image
                       (vector-ref (search-data-ref data 'image) 0))))
         (test-equal 3 (length (search-data-results data)))
         (test-equal '("future_group")
                     (map car (search-data-other data))))))

   (test-group "an empty data object is an empty search"
     (let ((data (search-response-data (decode "{\"meta\":{},\"data\":{}}"))))
       (test-equal '() (search-data-categories data))
       (test-equal 0 (length (search-data-results data)))
       (test-equal #() (search-data-ref data 'search))))

   (test-group "a result without a url or title is a decode error"
     (test-assert
      (catch 'kagi-error
        (lambda () (decode "{\"data\":{\"search\":[{\"title\":\"A\"}]}}") #f)
        (lambda (key err) (decode-error? err))))
     (test-assert
      (catch 'kagi-error
        (lambda () (decode "{\"data\":{\"search\":[{\"url\":\"https://a\"}]}}") #f)
        (lambda (key err) (decode-error? err)))))

   (test-group "a JSON output yields its response, not markdown"
     (let ((output (make-search-output-json (decode "{\"data\":{}}"))))
       (test-assert (search-output-json? output))
       (test-assert (not (search-output-markdown? output)))
       (test-assert (search-response? (search-output->json output)))
       (test-assert (catch 'kagi-error
                      (lambda () (search-output->markdown output) #f)
                      (lambda (key err) (unexpected-format-error? err))))))

   (test-group "a markdown output carries its trace and refuses to be JSON"
     (let ((output (make-search-output-markdown "# Results" "trace-md")))
       (test-assert (search-output-markdown? output))
       (test-equal "# Results" (search-output-markdown output))
       (test-equal "trace-md" (search-output-trace output))
       (test-assert (catch 'kagi-error
                      (lambda () (search-output->json output) #f)
                      (lambda (key err) (unexpected-format-error? err))))))))
