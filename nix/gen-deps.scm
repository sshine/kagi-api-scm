;;; Emit the in-tree module graph, for the per-module build in _package.nix.
;;;
;;; Each module names its imports in its own `define-module` form, so the graph can be
;;; read out of the sources instead of maintained by hand. `just gen-deps` writes
;;; nix/deps.json and `just ci` fails if it is stale.
;;;
;;; Read with Guile's own reader rather than a regex: `#:use-module ((intron term)
;;; #:select (strip-ansi))` is a list whose head is a list, and a pattern that gets
;;; that wrong would silently drop an edge.
(use-modules (ice-9 ftw)
             (ice-9 match)
             (srfi srfi-1)
             (ice-9 format))

(define (read-all path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((form (read port)))
          (if (eof-object? form) (reverse acc) (loop (cons form acc))))))))

(define (name->string name) (string-join (map symbol->string name) " "))

(define (spec-name spec)
  (name->string (if (list? (car spec)) (car spec) spec)))

;; Every module named by a #:use-module or a top-level use-modules, wherever it sits.
(define (specs-of form)
  (let loop ((x form) (acc '()))
    (match x
      ((? (lambda (v) (not (pair? v)))) acc)
      (((or 'quote 'quasiquote 'unquote) . _) acc)
      ((#:use-module spec . rest)
       (loop rest (if (list? spec) (cons (spec-name spec) acc) acc)))
      ((('use-modules . more) . rest)
       (loop (append more rest)
             (append (filter-map (lambda (s) (and (list? s) (spec-name s))) more) acc)))
      ((head . tail) (loop head (loop tail acc))))))

(define (module-name form)
  (match form
    (('define-module name . _) (and (list? name) (name->string name)))
    (_ #f)))

(define (walk dir)
  (append-map (lambda (entry)
                (let ((path (string-append dir "/" entry)))
                  (cond ((member entry '("." "..")) '())
                        ((eq? 'directory (stat:type (stat path))) (walk path))
                        ((string-suffix? ".scm" entry) (list path))
                        (else '()))))
              (scandir dir)))

(define (json-string text) (string-append "\"" text "\""))
(define (json-list items) (string-append "[" (string-join (map json-string items) ", ") "]"))

(define entries
  (filter-map
   (lambda (path)
     (let* ((forms (read-all path))
            (name (and (pair? forms) (module-name (car forms)))))
       (and name (list name path (specs-of (car forms))))))
   (sort (walk "src") string<?)))

(define names (map car entries))
(define (in-tree? name) (and (member name names) #t))

(define (entry->json entry)
  (let* ((name (car entry))
         (path (cadr entry))
         (specs (caddr entry))
         (in-tree (sort (filter in-tree? specs) string<?))
         (external (sort (filter (lambda (s) (not (in-tree? s))) specs) string<?)))
    (format #f "  ~a: { \"file\": ~a, \"deps\": ~a, \"external\": ~a }"
            (json-string name)
            (json-string path)
            (json-list in-tree)
            (json-list external))))

(format #t "{\n~a\n}\n" (string-join (map entry->json entries) ",\n"))
