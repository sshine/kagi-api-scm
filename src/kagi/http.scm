;;; The one HTTP call the search client makes.
;;;
;;; Guile's (web client) validates known headers against their grammars. The Rust client
;;; sends `Authorization: Bearer …`, an Accept with two media types and a User-Agent;
;;; declare-opaque-header! takes those out of the parsers so they pass through exactly as
;;; written, the same trick (intron http) uses for its provider headers.

(define-module (kagi http)
  #:use-module (kagi error)
  #:use-module (json)
  #:use-module (web client)
  #:use-module (web http)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:export (http-post-json
            response-header
            response-content-type-value
            response-body-string))

(eval-when (load eval expand)
  (declare-opaque-header! "Authorization")
  (declare-opaque-header! "User-Agent"))

(define* (http-post-json url payload #:key (headers '()))
  "POST PAYLOAD as JSON. Returns (values STATUS HEADERS BODY-STRING).

A transport failure is raised as a (kagi error) of kind transport, so the client can
decide whether another attempt is worth making. Nothing here retries: the search client
owns the attempt budget and the request counter."
  (catch #t
    (lambda ()
      (call-with-values
          (lambda ()
            (http-post url
                       #:body (scm->json-string payload)
                       #:headers headers
                       #:decode-body? #t))
        (lambda (response body)
          (values (response-code response)
                  (response-headers response)
                  (response-body-string body)))))
    (lambda (key . args)
      (raise-kagi-error
       (transport-error (format #f "POST ~a failed: ~a ~s" url key args)
                        args)))))

(define (response-body-string body)
  (cond ((string? body) body)
        ((bytevector? body) (utf8->string body))
        ((not body) "")
        (else (format #f "~a" body))))

(define (response-header headers name)
  "The value of header NAME (a string), or #f."
  (let ((value (assoc-ref headers (string->symbol (string-downcase name)))))
    (cond ((string? value) value)
          ((number? value) (number->string value))
          ((symbol? value) (symbol->string value))
          (else #f))))

(define (response-content-type-value response)
  "The media type of RESPONSE as a symbol, such as text/markdown, or #f."
  (let ((content-type (response-content-type response #f)))
    (and content-type (car content-type))))
