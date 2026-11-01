(use-modules (srfi srfi-64)
             (harness)
             (kagi api)
             (json))

(define (kagi-raises? thunk)
  (catch 'kagi-error
    (lambda () (thunk) #f)
    (lambda (key err) (kagi-error? err))))

(define (body request)
  (json-string->scm (search-request->json-string request)))

(run-suite
 "request"
 (lambda ()
   (test-group "a bare search sends only its query"
     (test-assert (json-equal? (body (make-search-request "steve jobs"))
                               '(("query" . "steve jobs")))))

   (test-group "an empty query is refused before a request"
     (for-each (lambda (query)
                 (test-assert (kagi-raises? (lambda () (make-search-request query)))))
               '("" "   " "\n\t")))

   (test-group "every option is sent under its documented name"
     (let ((request
            (make-search-request
             "steve jobs"
             #:workflow 'news
             #:format 'json
             #:lens-id "lens-1"
             #:lens (make-lens
                     #:sites-included '("kagi.com" "blog.kagi.com")
                     #:sites-excluded '("spam.example")
                     #:keywords-included '("privacy")
                     #:keywords-excluded '("crypto")
                     #:file-type "pdf"
                     #:time-after "2024-01-01"
                     #:time-before "2024-12-31"
                     #:time-relative 'month
                     #:search-region "us")
             #:timeout 2.5
             #:page 2
             #:limit 25
             #:filters (make-filters
                        #:region "no_region"
                        #:after "2023-06-01"
                        #:before "2023-12-31"
                        #:safe-search #f)
             #:extract (make-extract-options 3 #:timeout 1.5)
             #:personalizations
             (make-personalizations
              #:domains (list (make-domain-rule "example.com" 'raise))
              #:regexes (list (make-regex-rule "^https?://(www\\.)?reddit\\.com"
                                              #:replacement "https://old.reddit.com"))))))
       (test-assert
        (json-equal?
         (body request)
         '(("query" . "steve jobs")
           ("workflow" . "news")
           ("format" . "json")
           ("lens_id" . "lens-1")
           ("lens" ("sites_included" . #("kagi.com" "blog.kagi.com"))
                   ("sites_excluded" . #("spam.example"))
                   ("keywords_included" . #("privacy"))
                   ("keywords_excluded" . #("crypto"))
                   ("file_type" . "pdf")
                   ("time_after" . "2024-01-01")
                   ("time_before" . "2024-12-31")
                   ("time_relative" . "month")
                   ("search_region" . "US"))
           ("timeout" . 2.5)
           ("page" . 2)
           ("limit" . 25)
           ("filters" ("region" . "no_region")
                      ("after" . "2023-06-01")
                      ("before" . "2023-12-31")
                      ("safe_search" . #f))
           ("extract" ("count" . 3) ("timeout" . 1.5))
           ("personalizations"
            ("domains" . #((("domain" . "example.com") ("kind" . "raise"))))
            ("regexes" . #((("regex" . "^https?://(www\\.)?reddit\\.com")
                            ("replacement" . "https://old.reddit.com")))))))))

   (test-group "a lens omits what it does not constrain"
     (let ((lens (make-lens #:sites-included '("kagi.com")
                            #:time-relative 'week
                            #:search-region "us")))
       (test-assert
        (json-equal?
         (lens->json lens)
         '(("sites_included" . #("kagi.com"))
           ("time_relative" . "week")
           ("search_region" . "US"))))))

   (test-group "filters always send the safe-search flag"
     (test-assert (json-equal? (filters->json (make-filters))
                               '(("safe_search" . #t)))))

   (test-group "every out-of-range value is refused locally"
     (for-each
      (lambda (thunk)
        (test-assert (kagi-raises? thunk)))
      (list
       (lambda () (make-search-request "q" #:page 0))
       (lambda () (make-search-request "q" #:page 11))
       (lambda () (make-search-request "q" #:limit 0))
       (lambda () (make-search-request "q" #:limit 1025))
       (lambda () (make-search-request "q" #:timeout 0.4))
       (lambda () (make-search-request "q" #:timeout 4.1))
       (lambda () (make-search-request "q" #:workflow 'web))
       (lambda () (make-search-request "q" #:format 'html))
       (lambda () (make-search-request "q" #:lens-id " "))
       (lambda () (make-extract-options 0))
       (lambda () (make-extract-options 11))
       (lambda () (make-extract-options 1 #:timeout 5))
       (lambda () (make-lens #:time-after "01/01/2024"))
       (lambda () (make-lens #:time-after "2024-2-1"))
       (lambda () (make-lens #:search-region "USA"))
       (lambda () (make-lens #:file-type "a/b"))
       (lambda () (make-domain-rule "" 'block))
       (lambda () (make-domain-rule "a b" 'block))
       (lambda () (make-regex-rule "")))))

   (test-group "dates are exactly YYYY-MM-DD"
     (test-assert (lens? (make-lens #:time-after "2024-02-29")))
     (test-assert (kagi-raises? (lambda () (make-lens #:time-after "2024-02-30")))))

   (test-group "a client needs a key and an HTTP base URL"
     (test-assert (kagi-raises? (lambda () (make-client "  "))))
     (test-assert (kagi-raises? (lambda () (make-client "k" #:base-url "ftp://x"))))
     (test-assert (kagi-raises? (lambda () (make-client "k" #:base-url ""))))
     (let ((client (make-client "KG_test" #:base-url "https://kagi.com/api/v1/")))
       (test-equal "https://kagi.com/api/v1" (client-base-url client))
       (test-equal 0 (client-requests-made client))))))
)
