(use-modules (srfi srfi-64)
             (srfi srfi-13)
             (harness)
             (kagi error))

(run-suite
 "error"
 (lambda ()
   (test-group "the live v1 spelling is errors"
     (let ((err (parse-api-error
                 "{\"meta\":{\"trace\":\"abc\"},\"data\":null,\"errors\":[{\"code\":\"2\",\"url\":\"https://help\",\"message\":\"Unauthorized\",\"location\":null}]}")))
       (test-equal "2" (api-error-code err))
       (test-equal "Unauthorized" (api-error-message err))
       (test-equal 1 (vector-length (api-error-details err)))
       (test-equal "abc" (assoc-ref (api-error-meta err) "trace"))))

   (test-group "the spec spelling is error"
     (let ((err (parse-api-error
                 "{\"error\":[{\"code\":\"BAD\",\"url\":\"https://x\",\"message\":\"broken\"}]}")))
       (test-equal "BAD" (api-error-code err))
       (test-equal "broken" (api-error-message err))))

   (test-group "v0 spells the members msg and ref, with a numeric code"
     (let ((err (parse-api-error
                 "{\"meta\":{\"id\":\"v0\",\"node\":\"us-central1\",\"ms\":1},\"data\":null,\"error\":[{\"code\":2,\"msg\":\"Unauthorized\",\"ref\":null}]}")))
       (test-equal "2" (api-error-code err))
       (test-equal "Unauthorized" (api-error-message err))
       (test-equal "us-central1" (assoc-ref (api-error-meta err) "node"))))

   (test-group "several details are all kept and rendered"
     (let ((err (parse-api-error
                 "{\"errors\":[{\"code\":\"a.b\",\"message\":\"one\",\"location\":\"pages[0]\"},{\"code\":\"c.d\",\"message\":\"two\"}]}")))
       (test-equal 2 (vector-length (api-error-details err)))
       (test-equal "a.b" (api-error-code err))
       (test-equal "a.b: one (at pages[0]); c.d: two" (api-error->string err))))

   (test-group "a body that is not a document keeps its text"
     (let ((err (parse-api-error "<html>502 Bad Gateway</html>")))
       (test-equal 0 (vector-length (api-error-details err)))
       (test-equal #f (api-error-code err))
       (test-assert (string-contains (api-error-message err) "502"))))

   (test-group "an empty error array is not a document"
     (let ((err (parse-api-error "{\"meta\":{\"trace\":\"x\"},\"error\":[]}")))
       (test-equal 0 (vector-length (api-error-details err)))
       (test-equal #f (api-error-meta err))))

   (test-group "predicates read the kind and status they name"
     (let ((invalid (invalid-field "limit" "must be 1 to 1024" 0))
           (unauthorized (api-error 401 (parse-api-error "{\"errors\":[{\"code\":\"2\",\"message\":\"Unauthorized\"}]}")))
           (forbidden (api-error 403 (parse-api-error "")))
           (bad-token (api-error 400 (parse-api-error "{\"errors\":[{\"code\":\"general.invalid_token\",\"message\":\"bad\"}]}")))
           (rate (rate-limited-error 1 60 (parse-api-error "")))
           (server (api-error 503 (parse-api-error ""))))
       (test-assert (invalid-error? invalid))
       (test-assert (validation-error? invalid))
       (test-assert (unauthorized-error? unauthorized))
       (test-assert (forbidden-error? forbidden))
       (test-assert (unauthorized-error? bad-token))
       (test-assert (validation-error? bad-token))
       (test-assert (rate-limited? rate))
       (test-assert (server-error? server))
       (test-assert (not (server-error? forbidden)))))))
