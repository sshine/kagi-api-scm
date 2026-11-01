;;; A minimal stand-in for the Kagi search endpoint.
;;;
;;; The difference between "the request builder is written" and "the client sends what the
;;; builder says", and the only way to exercise retries, auth headers and content-type
;;; handling without a key. It records each request, so a test can assert on the bearer
;;; token and the JSON body rather than only on the decoded answer.
;;;
;;; One connection per response, in order. A response is an alist:
;;;
;;;   ((status . 200)
;;;    (content-type . "application/json")
;;;    (headers . (("x-kagi-trace" . "abc")))
;;;    (body . "{\"meta\":{},\"data\":{}}"))
;;;
;;; The body is written verbatim; content-length is computed.

(define-module (fake-kagi)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:export (with-fake-kagi
            requests
            last-request
            request-method
            request-path
            request-header
            request-body
            json-response
            markdown-response))

(define %requests '())

(define (requests) (reverse %requests))
(define (last-request) (and (pair? %requests) (car %requests)))

(define (request-method request) (assoc-ref request "method"))
(define (request-path request) (assoc-ref request "path"))
(define (request-body request) (assoc-ref request "body"))
(define (request-header request name)
  (assoc-ref (assoc-ref request "headers") name))

(define (read-headers port)
  (let loop ((acc '()))
    (let ((line (read-line port)))
      (cond
       ((eof-object? line) (reverse acc))
       ((or (string=? line "") (string=? line "\r")) (reverse acc))
       (else
        (let* ((line (if (string-suffix? "\r" line)
                         (substring line 0 (- (string-length line) 1))
                         line))
               (colon (string-index line #\:)))
          (loop (if colon
                    (cons (cons (string-downcase (substring line 0 colon))
                                (string-trim (substring line (+ colon 1))))
                          acc)
                    acc))))))))

(define (content-length headers)
  (let ((value (assoc-ref headers "content-length")))
    (if value (or (string->number value) 0) 0)))

(define (read-request cli)
  (let* ((request-line (read-line cli))
         (parts (and request-line (string-split request-line #\space)))
         (method (and parts (list-ref parts 0)))
         (path (and parts (list-ref parts 1)))
         (headers (read-headers cli))
         (n (content-length headers))
         (body (if (> n 0) (get-string-n cli n) "")))
    `(("method" . ,method)
      ("path" . ,path)
      ("headers" . ,headers)
      ("body" . ,body))))

(define (write-response cli response)
  (let* ((status (assoc-ref response 'status))
         (content-type (or (assoc-ref response 'content-type) "application/json"))
         (extra (or (assoc-ref response 'headers) '()))
         (body (or (assoc-ref response 'body) "")))
    (format cli "HTTP/1.1 ~a OK\r\n" status)
    (format cli "content-type: ~a\r\n" content-type)
    (format cli "content-length: ~a\r\n" (string-length body))
    (for-each (lambda (header)
                (format cli "~a: ~a\r\n" (car header) (cdr header)))
              extra)
    (display "\r\n" cli)
    (display body cli)
    (force-output cli)))

(define (serve-one sock response)
  (let ((pair (accept sock)))
    (let ((cli (car pair)))
      (let ((request (read-request cli)))
        (set! %requests (cons request %requests))
        (write-response cli response)
        (force-output cli)
        (close-port cli)))))

(define (serve sock responses)
  (for-each (lambda (response) (serve-one sock response)) responses))

(define* (with-fake-kagi responses proc)
  "Serve RESPONSES in order, calling PROC with the base URL."
  (set! %requests '())
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (bind sock AF_INET INADDR_LOOPBACK 0)
    (listen sock 8)
    (let* ((port-number (sockaddr:port (getsockname sock)))
           (base (format #f "http://127.0.0.1:~a" port-number))
           (server (call-with-new-thread
                    (lambda ()
                      (catch #t
                        (lambda () (serve sock responses))
                        (lambda _ #f))))))
      (dynamic-wind
        (lambda () #f)
        (lambda () (proc base))
        (lambda ()
          (false-if-exception (join-thread server 5))
          (false-if-exception (close-port sock)))))))

(define* (json-response body #:key (status 200) (trace #f))
  `((status . ,status)
    (content-type . "application/json")
    (headers . ,(if trace (list (cons "x-kagi-trace" trace)) '()))
    (body . ,body)))

(define* (markdown-response body #:key (status 200) (trace #f))
  `((status . ,status)
    (content-type . "text/markdown; charset=utf-8")
    (headers . ,(if trace (list (cons "x-kagi-trace" trace)) '()))
    (body . ,body)))
