;;; The Kagi v1 Search API, ported from the Rust client.
;;;
;;; The shape follows `crates/kagi-api/src/api/search.rs`: a client with a request count
;;; and retry budget, a validated request built from keyword arguments, a response split
;;; into named categories, and an output that is either JSON or markdown because the
;;; server decides which arrived. The differences are the language: values are records
;;; and alists, and the HTTP call is synchronous.
;;;
;;; Only the v1 Search endpoint is here. Extraction and the v0 products are deliberately
;;; out of scope for this port.

(define-module (kagi search)
  #:use-module (kagi error)
  #:use-module (kagi http)
  #:use-module (json)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
    #:export (;; client
            make-client
            client?
            client-api-key
            client-base-url
            client-user-agent
            client-max-retries
            client-max-retry-delay
            client-initial-backoff
            client-requests-made

            ;; request values
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

            ;; response values
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

            ;; output values
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

            ;; calls
            client-search
            client-search-json
            client-search-markdown))

;;; The client.

(define-record-type <client>
  (%make-client api-key base-url user-agent max-retries max-retry-delay
                initial-backoff requests-made)
  client?
  (api-key          client-api-key)
  (base-url         client-base-url)
  (user-agent       client-user-agent)
  (max-retries      client-max-retries)
  (max-retry-delay  client-max-retry-delay)
  (initial-backoff  client-initial-backoff)
  (requests-made    client-requests-made set-client-requests-made!))

(define %default-base-url "https://kagi.com/api/v1")
(define %default-user-agent "kagi-api-scm/0.1.0")

(define* (make-client api-key
                      #:key
                      (base-url %default-base-url)
                      (user-agent %default-user-agent)
                      (max-retries 3)
                      (max-retry-delay 60)
                      (initial-backoff 0.5))
  "Build a client. Raises an invalid error for a key that cannot authenticate."
  (when (or (not (string? api-key))
            (string-null? (string-trim-both api-key)))
    (raise-kagi-error (invalid-field "api_key" "must not be empty" (or api-key ""))))
  (when (or (not (string? base-url))
            (string-null? (string-trim-both base-url)))
    (raise-kagi-error (invalid-field "base_url" "must not be empty"
                                     (or base-url ""))))
  (unless (or (string-prefix? "http://" base-url)
              (string-prefix? "https://" base-url))
    (raise-kagi-error (invalid-field "base_url" "must be HTTP or HTTPS" base-url)))
  (when (or (not (string? user-agent))
            (string-null? (string-trim-both user-agent)))
    (raise-kagi-error (invalid-field "user_agent" "must not be empty"
                                     (or user-agent ""))))
  (when (not (and (integer? max-retries) (>= max-retries 0)))
    (raise-kagi-error (invalid-field "max_retries" "must be a non-negative integer"
                                     max-retries)))
  (when (not (and (real? max-retry-delay) (> max-retry-delay 0)))
    (raise-kagi-error (invalid-field "max_retry_delay" "must be positive"
                                     max-retry-delay)))
  (when (not (and (real? initial-backoff) (> initial-backoff 0)))
    (raise-kagi-error (invalid-field "initial_backoff" "must be positive"
                                     initial-backoff)))
  (%make-client (string-trim-both api-key)
                (trim-trailing-slash base-url)
                user-agent
                max-retries
                max-retry-delay
                initial-backoff
                0))

(define (trim-trailing-slash url)
  (let loop ((url url))
    (if (and (> (string-length url) 0)
             (char=? (string-ref url (- (string-length url) 1)) #\/))
        (loop (substring url 0 (- (string-length url) 1)))
        url)))

;;; Request values and their validation.

(define (one-of field value allowed)
  (unless (member value allowed)
    (raise-kagi-error
     (invalid-field field
                    (string-append "must be one of "
                                   (string-join (map symbol->string allowed) ", "))
                    value)))
  value)

(define (check-page page)
  (unless (and (integer? page) (<= 1 page 10))
    (raise-kagi-error (invalid-field "page" "must be between 1 and 10" page)))
  page)

(define (check-limit limit)
  (unless (and (integer? limit) (<= 1 limit 1024))
    (raise-kagi-error (invalid-field "limit" "must be between 1 and 1024" limit)))
  limit)

(define (check-search-timeout timeout)
  (unless (and (real? timeout) (<= 0.5 timeout 4.0))
    (raise-kagi-error
     (invalid-field "timeout" "must be between 0.5 and 4 seconds" timeout)))
  timeout)

(define (check-extract-timeout timeout)
  (unless (and (real? timeout) (<= 0.5 timeout 10.0))
    (raise-kagi-error
     (invalid-field "timeout" "must be between 0.5 and 10 seconds" timeout)))
  timeout)

(define (check-workflow workflow)
  (one-of "workflow" workflow '(search images videos news podcasts)))

(define (check-format format)
  (one-of "format" format '(json markdown)))

(define (check-time-relative interval)
  (one-of "time_relative" interval '(day week month)))

(define (check-personalization-kind kind)
  (one-of "kind" kind '(block lower raise pin)))

(define (digits? text)
  (string-every char-numeric? text))

(define (leap-year? year)
  (or (zero? (modulo year 400))
      (and (zero? (modulo year 4)) (not (zero? (modulo year 100))))))

(define (days-in-month year month)
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    ((2) (if (leap-year? year) 29 28))
    (else 0)))

(define (check-date date)
  (unless (and (string? date)
               (= (string-length date) 10)
               (char=? (string-ref date 4) #\-)
               (char=? (string-ref date 7) #\-)
               (digits? (substring date 0 4))
               (digits? (substring date 5 7))
               (digits? (substring date 8 10))
               (let ((year (string->number (substring date 0 4)))
                     (month (string->number (substring date 5 7)))
                     (day (string->number (substring date 8 10))))
                 (and (<= 1 month 12)
                      (<= 1 day (days-in-month year month)))))
    (raise-kagi-error
     (invalid-field "date" "must be a date in YYYY-MM-DD form" date)))
  date)

(define (check-region region)
  (unless (string? region)
    (raise-kagi-error (invalid-field "region" "must be a string" region)))
  (cond ((string=? region "no_region") region)
        ((and (= (string-length region) 2)
              (string-every char-alphabetic? region))
         (string-upcase region))
        (else
         (raise-kagi-error
          (invalid-field "region" "must be an ISO 3166-1 alpha-2 code or no_region"
                         region)))))

(define (check-file-type file-type)
  (unless (and (string? file-type)
               (> (string-length file-type) 0)
               (<= (string-length file-type) 32)
               (string-every (lambda (c)
                               (or (char-alphanumeric? c)
                                   (memv c '(#\. #\+ #\-))))
                             file-type))
    (raise-kagi-error
     (invalid-field "file_type" "must be 1 to 32 letters, digits or . + -"
                    file-type)))
  file-type)

(define (char-alphanumeric? c)
  (or (char-alphabetic? c) (char-numeric? c)))

(define (check-query query)
  (when (or (not (string? query)) (string-null? (string-trim-both query)))
    (raise-kagi-error (invalid-field "query" "must not be empty" (or query ""))))
  query)

(define (check-lens-id lens-id)
  (when (or (not (string? lens-id)) (string-null? (string-trim-both lens-id)))
    (raise-kagi-error (invalid-field "lens_id" "must not be empty"
                                     (or lens-id ""))))
  lens-id)

(define (check-domain domain)
  (unless (and (string? domain)
               (> (string-length domain) 0)
               (<= (string-length domain) 253)
               (string-every (lambda (c)
                               (or (char-alphanumeric? c)
                                   (memv c '(#\. #\- #\_ #\*))))
                             domain))
    (raise-kagi-error
     (invalid-field "personalizations.domains.domain"
                    "must be 1 to 253 letters, digits or . - _ *"
                    domain)))
  domain)

(define (check-regex regex)
  (unless (and (string? regex)
               (> (string-length regex) 0)
               (<= (string-length regex) 1000))
    (raise-kagi-error
     (invalid-field "personalizations.regexes.regex"
                    "must be between 1 and 1000 bytes"
                    regex)))
  regex)

(define (string-vector field value)
  "Coerce VALUE to a vector of strings, rejecting anything else."
  (let ((vec (cond ((vector? value) value)
                   ((list? value) (list->vector value))
                   ((not value) #())
                   (else
                    (raise-kagi-error
                     (invalid-field field "must be a list of strings" value))))))
    (for-each
     (lambda (item)
       (unless (string? item)
         (raise-kagi-error (invalid-field field "must contain only strings" item))))
     (vector->list vec))
    vec))

(define (tuple->vector items)
  (if (vector? items) items (list->vector (or items '()))))

;;; Inline lens.

(define-record-type <lens>
  (%make-lens sites-included sites-excluded keywords-included keywords-excluded
              file-type time-after time-before time-relative search-region)
  lens?
  (sites-included    lens-sites-included)
  (sites-excluded    lens-sites-excluded)
  (keywords-included lens-keywords-included)
  (keywords-excluded lens-keywords-excluded)
  (file-type         lens-file-type)
  (time-after        lens-time-after)
  (time-before       lens-time-before)
  (time-relative     lens-time-relative)
  (search-region     lens-search-region))

(define* (make-lens #:key
                    (sites-included #())
                    (sites-excluded #())
                    (keywords-included #())
                    (keywords-excluded #())
                    (file-type #f)
                    (time-after #f)
                    (time-before #f)
                    (time-relative #f)
                    (search-region #f))
  "Build an inline lens. Every field is optional and omitted when absent."
  (%make-lens (string-vector "lens.sites_included" sites-included)
              (string-vector "lens.sites_excluded" sites-excluded)
              (string-vector "lens.keywords_included" keywords-included)
              (string-vector "lens.keywords_excluded" keywords-excluded)
              (and file-type (check-file-type file-type))
              (and time-after (check-date time-after))
              (and time-before (check-date time-before))
              (and time-relative (check-time-relative time-relative))
              (and search-region (check-region search-region))))

(define (lens->json lens)
  (append
   (if (> (vector-length (lens-sites-included lens)) 0)
       (list (cons "sites_included" (lens-sites-included lens))) '())
   (if (> (vector-length (lens-sites-excluded lens)) 0)
       (list (cons "sites_excluded" (lens-sites-excluded lens))) '())
   (if (> (vector-length (lens-keywords-included lens)) 0)
       (list (cons "keywords_included" (lens-keywords-included lens))) '())
   (if (> (vector-length (lens-keywords-excluded lens)) 0)
       (list (cons "keywords_excluded" (lens-keywords-excluded lens))) '())
   (if (lens-file-type lens)
       (list (cons "file_type" (lens-file-type lens))) '())
   (if (lens-time-after lens)
       (list (cons "time_after" (lens-time-after lens))) '())
   (if (lens-time-before lens)
       (list (cons "time_before" (lens-time-before lens))) '())
   (if (lens-time-relative lens)
       (list (cons "time_relative" (symbol->string (lens-time-relative lens)))) '())
   (if (lens-search-region lens)
       (list (cons "search_region" (lens-search-region lens))) '())))

;;; Result filters.

(define-record-type <filters>
  (%make-filters region after before safe-search)
  filters?
  (region      filters-region)
  (after       filters-after)
  (before      filters-before)
  (safe-search filters-safe-search?))

(define* (make-filters #:key (region #f) (after #f) (before #f) (safe-search #t))
  "Result filters. Safe search is on by default, as the API specifies."
  (%make-filters (and region (check-region region))
                 (and after (check-date after))
                 (and before (check-date before))
                 (if safe-search #t #f)))

(define (filters->json filters)
  (append
   (if (filters-region filters)
       (list (cons "region" (filters-region filters))) '())
   (if (filters-after filters)
       (list (cons "after" (filters-after filters))) '())
   (if (filters-before filters)
       (list (cons "before" (filters-before filters))) '())
   (list (cons "safe_search" (filters-safe-search? filters)))))

;;; Extraction of the top results.

(define-record-type <extract-options>
  (%make-extract-options count timeout)
  extract-options?
  (count   extract-options-count)
  (timeout extract-options-timeout))

(define* (make-extract-options count #:key (timeout #f))
  "Extract content from COUNT top results, from 1 to 10."
  (unless (and (integer? count) (<= 1 count 10))
    (raise-kagi-error
     (invalid-field "extract.count" "must be between 1 and 10" count)))
  (%make-extract-options count
                         (and timeout (check-search-timeout timeout))))

(define (extract-options->json extract)
  (append (list (cons "count" (extract-options-count extract)))
          (if (extract-options-timeout extract)
              (list (cons "timeout" (extract-options-timeout extract))) '())))

;;; Personalizations.

(define-record-type <domain-rule>
  (%make-domain-rule domain kind)
  domain-rule?
  (domain domain-rule-domain)
  (kind   domain-rule-kind))

(define (make-domain-rule domain kind)
  "A domain pattern and how to treat its results."
  (%make-domain-rule (check-domain domain) (check-personalization-kind kind)))

(define-record-type <regex-rule>
  (%make-regex-rule regex replacement)
  regex-rule?
  (regex       regex-rule-regex)
  (replacement regex-rule-replacement))

(define* (make-regex-rule regex #:key (replacement ""))
  "A regex and what to replace it with. An empty replacement removes the match."
  (%make-regex-rule (check-regex regex) (or replacement "")))

(define-record-type <personalizations>
  (%make-personalizations domains regexes)
  personalizations?
  (domains personalizations-domains)
  (regexes personalizations-regexes))

(define* (make-personalizations #:key (domains #()) (regexes #()))
  "Ranking rules. At most 1000 of each, as the API documents."
  (let ((domains (tuple->vector domains))
        (regexes (tuple->vector regexes)))
    (for-each
     (lambda (rule)
       (unless (domain-rule? rule)
         (raise-kagi-error (invalid-field "personalizations.domains"
                                          "must contain domain rules" rule))))
     (vector->list domains))
    (for-each
     (lambda (rule)
       (unless (regex-rule? rule)
         (raise-kagi-error (invalid-field "personalizations.regexes"
                                          "must contain regex rules" rule))))
     (vector->list regexes))
    (when (> (vector-length domains) 1000)
      (raise-kagi-error
       (invalid-field "personalizations.domains" "may contain at most 1000 rules"
                      (vector-length domains))))
    (when (> (vector-length regexes) 1000)
      (raise-kagi-error
       (invalid-field "personalizations.regexes" "may contain at most 1000 rules"
                      (vector-length regexes))))
    (%make-personalizations domains regexes)))

(define (personalizations->json personalizations)
  (append
   (if (> (vector-length (personalizations-domains personalizations)) 0)
       (list (cons "domains"
                   (list->vector
                    (map (lambda (rule)
                           `(("domain" . ,(domain-rule-domain rule))
                             (kind . ,(symbol->string (domain-rule-kind rule)))))
                         (vector->list (personalizations-domains personalizations))))))
       '())
   (if (> (vector-length (personalizations-regexes personalizations)) 0)
       (list (cons "regexes"
                   (list->vector
                    (map (lambda (rule)
                           `(("regex" . ,(regex-rule-regex rule))
                             (replacement . ,(regex-rule-replacement rule))))
                         (vector->list (personalizations-regexes personalizations))))))
       '())))

;;; The search request.

(define-record-type <search-request>
  (%make-search-request query workflow format lens-id lens timeout page limit
                        filters extract personalizations)
  search-request?
  (query            search-request-query)
  (workflow         search-request-workflow)
  (format           search-request-format)
  (lens-id          search-request-lens-id)
  (lens             search-request-lens)
  (timeout          search-request-timeout)
  (page             search-request-page)
  (limit            search-request-limit)
  (filters          search-request-filters)
  (extract          search-request-extract)
  (personalizations search-request-personalizations))

(define* (make-search-request query
                              #:key
                              (workflow #f)
                              (format #f)
                              (lens-id #f)
                              (lens #f)
                              (timeout #f)
                              (page #f)
                              (limit #f)
                              (filters #f)
                              (extract #f)
                              (personalizations #f))
  "Build a validated search request.

Raises an invalid error for a value the API would reject anyway, so a request is not
spent finding out."
  (when (and lens (not (lens? lens)))
    (raise-kagi-error (invalid-field "lens" "must be a lens" lens)))
  (when (and filters (not (filters? filters)))
    (raise-kagi-error (invalid-field "filters" "must be filters" filters)))
  (when (and extract (not (extract-options? extract)))
    (raise-kagi-error (invalid-field "extract" "must be extract options" extract)))
  (when (and personalizations (not (personalizations? personalizations)))
    (raise-kagi-error (invalid-field "personalizations" "must be personalizations"
                                     personalizations)))
  (%make-search-request (check-query query)
                        (and workflow (check-workflow workflow))
                        (and format (check-format format))
                        (and lens-id (check-lens-id lens-id))
                        lens
                        (and timeout (check-search-timeout timeout))
                        (and page (check-page page))
                        (and limit (check-limit limit))
                        filters
                        extract
                        personalizations))

(define (search-request->json request)
  "The request body as guile-json's alist representation."
  (append
   (list (cons "query" (search-request-query request)))
   (if (search-request-workflow request)
       (list (cons "workflow" (symbol->string (search-request-workflow request)))) '())
   (if (search-request-format request)
       (list (cons "format" (symbol->string (search-request-format request)))) '())
   (if (search-request-lens-id request)
       (list (cons "lens_id" (search-request-lens-id request))) '())
   (if (search-request-lens request)
       (list (cons "lens" (lens->json (search-request-lens request)))) '())
   (if (search-request-timeout request)
       (list (cons "timeout" (search-request-timeout request))) '())
   (if (search-request-page request)
       (list (cons "page" (search-request-page request))) '())
   (if (search-request-limit request)
       (list (cons "limit" (search-request-limit request))) '())
   (if (search-request-filters request)
       (list (cons "filters" (filters->json (search-request-filters request)))) '())
   (if (search-request-extract request)
       (list (cons "extract" (extract-options->json (search-request-extract request)))) '())
   (if (search-request-personalizations request)
       (list (cons "personalizations"
                   (personalizations->json
                    (search-request-personalizations request)))) '())))

(define (search-request->json-string request)
  (scm->json-string (search-request->json request)))

;;; The response.

(define %search-categories
  '(search image video podcast podcast_creator news adjacent_question direct_answer
    interesting_news interesting_finds infobox code package_tracking public_records
    weather related_search listicle web_archive))

(define (search-categories)
  "Every category the API documents, in canonical order."
  %search-categories)

(define-record-type <search-image>
  (%make-search-image url width height)
  search-image?
  (url    search-image-url)
  (width  search-image-width)
  (height search-image-height))

(define-record-type <search-result>
  (%make-search-result url title snippet time image props)
  search-result?
  (url     search-result-url)
  (title   search-result-title)
  (snippet search-result-snippet)
  (time    search-result-time)
  (image   search-result-image)
  (props   search-result-props))

(define-record-type <search-data>
  (%make-search-data groups other)
  search-data?
  (groups search-data-groups)
  (other  search-data-other))

(define-record-type <search-response>
  (%make-search-response meta data)
  search-response?
  (meta search-response-meta)
  (data search-response-data))

(define (required-string alist key what)
  (let ((value (assoc-ref alist key)))
    (if (string? value)
        value
        (raise-kagi-error
         (decode-error (format #f "search result has no string ~a" what)
                       (format #f "~s" alist)
                       #f)))))

(define (json-null? value) (eq? value (quote null)))

(define (nullable value)
  (if (json-null? value) #f value))

(define (json->search-image alist)
  (and alist
       (not (json-null? alist))
       (%make-search-image (or (assoc-ref alist "url") "")
                           (assoc-ref alist "width")
                           (assoc-ref alist "height"))))

(define (json->search-result alist)
  (unless (list? alist)
    (raise-kagi-error (decode-error "expected a search result object"
                                    (format #f "~s" alist) #f)))
  (%make-search-result (required-string alist "url" "url")
                       (required-string alist "title" "title")
                       (nullable (assoc-ref alist "snippet"))
                       (nullable (assoc-ref alist "time"))
                       (json->search-image (nullable (assoc-ref alist "image")))
                       (nullable (assoc-ref alist "props"))))

(define (json->search-data alist)
  (let* ((alist (if (list? alist) alist '()))
         (groups
          (map (lambda (category)
                 (let ((raw (assoc-ref alist (symbol->string category))))
                   (cons category
                         (if (vector? raw)
                             (list->vector
                              (map json->search-result (vector->list raw)))
                             #()))))
               %search-categories))
         (other (filter (lambda (pair)
                          (not (member (car pair) (map symbol->string %search-categories))))
                        alist)))
    (%make-search-data groups other)))

(define (json->search-response alist)
  (unless (list? alist)
    (raise-kagi-error
     (decode-error "expected a search response object" (format #f "~s" alist) #f)))
  (%make-search-response (or (nullable (assoc-ref alist "meta")) '())
                         (json->search-data (nullable (assoc-ref alist "data")))))

(define (search-response-trace response)
  (assoc-ref (search-response-meta response) "trace"))

(define (search-data-ref data category)
  (or (assoc-ref (search-data-groups data) category) #()))

(define (search-data-categories data)
  (filter (lambda (category)
            (> (vector-length (search-data-ref data category)) 0))
          %search-categories))

(define (search-data-results data)
  (append-map (lambda (category)
                (vector->list (search-data-ref data category)))
              %search-categories))

;;; What a search actually answered with.

(define-record-type <search-output>
  (%make-search-output kind response markdown trace)
  search-output?
  (kind     search-output-kind)
  (response search-output-response)
  (markdown search-output-markdown)
  (trace    search-output-trace))

(define (make-search-output-json response)
  (%make-search-output 'json response #f (search-response-trace response)))

(define (make-search-output-markdown text trace)
  (%make-search-output 'markdown #f text trace))

(define (search-output-json? output)
  (eq? (search-output-kind output) 'json))

(define (search-output-markdown? output)
  (eq? (search-output-kind output) 'markdown))

(define (search-output->json output)
  (if (search-output-json? output)
      (search-output-response output)
      (raise-kagi-error (unexpected-format-error "JSON" "markdown"))))

(define (search-output->markdown output)
  (if (search-output-markdown? output)
      (search-output-markdown output)
      (raise-kagi-error (unexpected-format-error "markdown" "JSON"))))

;;; The call.

(define (sleep-seconds seconds)
  (when (> seconds 0)
    (usleep (inexact->exact (round (* seconds 1000000))))))

(define (backoff client attempt)
  (min (client-max-retry-delay client)
       (* (client-initial-backoff client)
          (expt 2 (- attempt 1)))))

(define (content-type-of headers)
  (let ((value (assoc-ref headers 'content-type)))
    (cond ((symbol? value) value)
          ((pair? value) (car value))
          ((string? value)
           (string->symbol (car (string-split value #\;))))
          (else #f))))

(define (markdown-content-type? content-type)
  (or (eq? content-type 'text/markdown)
      (eq? content-type 'text/x-markdown)))

(define (decode-search-output headers body)
  (let ((content-type (content-type-of headers)))
    (if (markdown-content-type? content-type)
        (make-search-output-markdown body (response-header headers "x-kagi-trace"))
        (let ((decoded (catch #t
                         (lambda () (json-string->scm body))
                         (lambda _ #f))))
          (if (list? decoded)
              (make-search-output-json (json->search-response decoded))
              (raise-kagi-error
               (decode-error "expected a search response"
                             body
                             #f)))))))

(define (post-once client url payload headers)
  "Returns (response STATUS HEADERS BODY) or (error ERR)."
  (catch 'kagi-error
    (lambda ()
      (call-with-values
          (lambda () (http-post-json url payload #:headers headers))
        (lambda (status response-headers body)
          (list 'response status response-headers body))))
    (lambda (key err)
      (list 'error err))))

(define* (client-search client request)
  "POST /search. Returns a <search-output>, retrying 429s and 5xxs.

A 429 honours Retry-After when it is a number of seconds; an HTTP-date is not parsed,
and the exponential backoff is used instead."
  (let* ((url (string-append (client-base-url client) "/search"))
         (payload (search-request->json request))
         (headers `((authorization . ,(string-append "Bearer "
                                                     (client-api-key client)))
                    (content-type application/json (charset . "utf-8"))
                    (user-agent . ,(client-user-agent client))))
         (max-retries (client-max-retries client)))
    (let loop ((attempt 1))
      (set-client-requests-made! client (+ 1 (client-requests-made client)))
      (match (post-once client url payload headers)
        (('error err)
         (if (transport-error? err)
             (if (<= attempt max-retries)
                 (begin (sleep-seconds (backoff client attempt))
                        (loop (+ attempt 1)))
                 (raise-kagi-error err))
             (raise-kagi-error err)))
        (('response status response-headers body)
         (cond
          ((= status 429)
           (let* ((retry-after-text (response-header response-headers
                                                     "retry-after"))
                  (retry-after (and retry-after-text
                                    (string->number retry-after-text)))
                  (delay (or retry-after (backoff client attempt))))
             (if (or (> attempt max-retries)
                     (> delay (client-max-retry-delay client)))
                 (raise-kagi-error
                  (rate-limited-error attempt retry-after
                                      (parse-api-error body)))
                 (begin (sleep-seconds delay)
                        (loop (+ attempt 1))))))
          ((and (>= status 500) (<= status 599))
           (if (<= attempt max-retries)
               (begin (sleep-seconds (backoff client attempt))
                      (loop (+ attempt 1)))
               (raise-kagi-error (api-error status (parse-api-error body)))))
          ((not (and (>= status 200) (<= status 299)))
           (raise-kagi-error (api-error status (parse-api-error body))))
          (else
           (decode-search-output response-headers body))))))))

(define (client-search-json client request)
  (search-output->json (client-search client request)))

(define (client-search-markdown client request)
  (search-output->markdown (client-search client request)))
