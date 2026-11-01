;;; The public face of the port.
;;;
;;; `(use-modules (kagi api))` is the one import Intron needs. The split below keeps the
;;; implementation in `(kagi search)` and `(kagi error)` while matching the Rust crate
;;; root, which re-exports its client, request, response and error types.

(define-module (kagi api)
  #:use-module (kagi search)
  #:use-module (kagi error)
  #:re-export (make-client
               client?
               client-api-key
               client-base-url
               client-user-agent
               client-max-retries
               client-max-retry-delay
               client-initial-backoff
               client-requests-made

               make-search-request
               search-request?
               search-request-query
               search-request-workflow
               search-request-format
               search-request-lens-id
               search-request-lens
               search-request-timeout
               search-request-page
               search-request-limit
               search-request-filters
               search-request-extract
               search-request-personalizations
               search-request->json
               search-request->json-string

               make-lens
               lens?
               lens->json
               make-filters
               filters?
               filters->json
               filters-safe-search?
               make-extract-options
               extract-options?
               make-personalizations
               personalizations?
               make-domain-rule
               domain-rule?
               make-regex-rule
               regex-rule?

               search-response?
               search-response-meta
               search-response-data
               search-response-trace
               json->search-response
               json->search-data
               json->search-result
               search-data?
               search-data-ref
               search-data-categories
               search-data-results
               search-data-other
               search-result?
               search-result-url
               search-result-title
               search-result-snippet
               search-result-time
               search-result-image
               search-result-props
               search-image-url
               search-image-width
               search-image-height
               search-categories

               search-output?
               make-search-output-json
               make-search-output-markdown
               search-output-kind
               search-output-json?
               search-output-markdown?
               search-output-response
               search-output-markdown
               search-output-trace
               search-output->json
               search-output->markdown

               client-search
               client-search-json
               client-search-markdown

               kagi-error?
               kagi-error-kind
               kagi-error-message
               kagi-error-status
               kagi-error-body
               kagi-error-cause
               invalid-error
               invalid-field
               transport-error
               decode-error
               api-error
               rate-limited-error
               unexpected-format-error
               raise-kagi-error
               invalid-error?
               transport-error?
               decode-error?
               api-error?
               rate-limited-error?
               unexpected-format-error?
               unauthorized-error?
               forbidden-error?
               validation-error?
               server-error?
               rate-limited?
               error->string
               <api-error>
               api-error?
               api-error-details
               api-error-raw
               api-error-meta
               api-error-code
               api-error-message
               api-error-location
               parse-api-error
               api-error->string))
