;;; Errors, and the v1 error envelope.
;;;
;;; The Rust client models this as a `thiserror` enum. Scheme has no such thing, so the
;;; same information lives in one record with a `kind` symbol, and the predicates below
;;; are what callers branch on. The error envelope is parsed into a second record so a
;;; caller can inspect the server's code, message and location without re-parsing JSON.
;;;
;;; The live server spells the member `errors`; the spec says `error`. Both are accepted,
;;; and so are v0's `msg` and `ref` aliases, because the same parser is useful on any
;;; captured body.

(define-module (kagi error)
  #:use-module (ice-9 match)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-9)
  #:export (kagi-error?
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

;;; The crate-wide error.

(define-record-type <kagi-error>
  (%make-kagi-error kind message status body cause)
  kagi-error?
  (kind    kagi-error-kind)
  (message kagi-error-message)
  (status  kagi-error-status)
  (body    kagi-error-body)
  (cause   kagi-error-cause))

(define* (invalid-error message)
  "A value rejected by client-side validation, so no request was sent."
  (%make-kagi-error 'invalid message #f #f #f))

(define (invalid-field field reason value)
  "An invalid value, naming the field, why, and what was given."
  (invalid-error (format #f "invalid ~a: ~a (got ~s)" field reason value)))

(define (transport-error message cause)
  "The request never produced a response, or the body could not be read."
  (%make-kagi-error 'transport message #f #f cause))

(define (decode-error message body cause)
  "The response body did not match the expected shape."
  (%make-kagi-error 'decode message #f body cause))

(define (api-error status body)
  "The server answered with a status the client treats as an error."
  (%make-kagi-error 'api (api-error->string body) status body #f))

(define* (rate-limited-error attempts retry-after body)
  "The server kept answering 429 until the retry budget ran out."
  (%make-kagi-error 'rate-limited
                    (format #f "still rate limited after ~a attempts" attempts)
                    429
                    body
                    (cons attempts retry-after)))

(define (unexpected-format-error expected actual)
  "A successful response carried a body of the wrong kind."
  (%make-kagi-error 'unexpected-format
                    (format #f "expected ~a but the server answered with ~a"
                            expected actual)
                    #f
                    #f
                    #f))

(define (raise-kagi-error err)
  "Raise ERR for `(catch 'kagi-error ...)`."
  (throw 'kagi-error err))

(define (invalid-error? err) (eq? (kagi-error-kind err) 'invalid))
(define (transport-error? err) (eq? (kagi-error-kind err) 'transport))
(define (decode-error? err) (eq? (kagi-error-kind err) 'decode))
(define (api-error? err) (eq? (kagi-error-kind err) 'api))
(define (rate-limited-error? err) (eq? (kagi-error-kind err) 'rate-limited))
(define (unexpected-format-error? err)
  (eq? (kagi-error-kind err) 'unexpected-format))

(define (status-is? err code)
  (and (integer? (kagi-error-status err))
       (= (kagi-error-status err) code)))

(define (unauthorized-error? err)
  "True for 401, and for the v1 live server's 400 general.invalid_token."
  (or (status-is? err 401)
      (and (status-is? err 400)
           (let* ((body (kagi-error-body err))
                  (code (and (eq? (kagi-error-kind err) 'api)
                             (api-error-code body))))
             (and code
                  (or (string-contains code "invalid_token")
                      (string-contains code "unauthorized")))))))

(define (forbidden-error? err) (status-is? err 403))
(define (validation-error? err)
  (or (invalid-error? err) (status-is? err 400)))
(define (server-error? err)
  (and (integer? (kagi-error-status err))
       (<= 500 (kagi-error-status err) 599)))
(define (rate-limited? err)
  (or (rate-limited-error? err) (status-is? err 429)))

(define (error->string err)
  (kagi-error-message err))

;;; The server's error document.

(define-record-type <api-error>
  (%make-api-error details raw meta)
  api-error?
  (details api-error-details) ; vector of normalized detail alists
  (raw     api-error-raw)     ; always a string, truncated
  (meta    api-error-meta))   ; the response's meta alist, or #f

(define (nullable value)
  (if (eq? value (quote null)) #f value))

(define (stringify-code code)
  (cond ((string? code) code)
        ((number? code) (number->string code))
        ((symbol? code) (symbol->string code))
        (else (format #f "~s" code))))

(define (normalize-detail detail)
  "One error entry, with the spec, live v1 and v0 spellings all accepted."
  (let ((code (stringify-code (or (assoc-ref detail "code") "")))
        (url (nullable (or (assoc-ref detail "url") (assoc-ref detail "ref"))))
        (message (nullable (or (assoc-ref detail "message") (assoc-ref detail "msg"))))
        (location (nullable (assoc-ref detail "location"))))
    `((code . ,code)
      (url . ,url)
      (message . ,message)
      (location . ,location))))

(define (non-empty-vector? value)
  (and (vector? value) (> (vector-length value) 0)))

(define (parse-api-error body)
  "Parses an error body, falling back to its text when it is not a document."
  (let* ((raw (truncate (string-trim-both (or body "")) 4096))
         (decoded (catch #t
                    (lambda () (json-string->scm body))
                    (lambda _ #f)))
         (errors (and (list? decoded)
                      (or (assoc-ref decoded "errors")
                          (assoc-ref decoded "error")))))
    (if (non-empty-vector? errors)
        (%make-api-error
         (list->vector (map normalize-detail (vector->list errors)))
         raw
         (nullable (assoc-ref decoded "meta")))
        (%make-api-error #() raw #f))))

(define (api-error-primary err)
  (let ((details (api-error-details err)))
    (and (> (vector-length details) 0) (vector-ref details 0))))

(define (api-error-code err)
  (let ((primary (api-error-primary err)))
    (and primary (assoc-ref primary 'code))))

(define (api-error-message err)
  (let ((primary (api-error-primary err)))
    (or (and primary (assoc-ref primary 'message))
        (api-error-raw err))))

(define (api-error-location err)
  (let ((primary (api-error-primary err)))
    (and primary (assoc-ref primary 'location))))

(define (api-error->string err)
  "Render every detail, or the raw body when there was no document."
  (let ((details (api-error-details err)))
    (if (zero? (vector-length details))
        (api-error-raw err)
        (string-join
         (map (lambda (detail)
                (let ((code (assoc-ref detail 'code))
                      (message (assoc-ref detail 'message))
                      (location (assoc-ref detail 'location)))
                  (string-append code ": " (or message code)
                                 (if location
                                     (string-append " (at " location ")")
                                     ""))))
              (vector->list details))
         "; "))))

(define (truncate text max)
  (if (<= (string-length text) max)
      text
      (string-append (substring text 0 max) "…")))
