(define-module (spartan build config-files)
  #:use-module (srfi srfi-1)
  #:export (relative-file-name? paths-overlap?))

(define (relative-file-name? path)
  (and (string? path)
       (not (string-any (lambda (char) (char<? char #\space)) path))
       (every (lambda (part) (not (member part '("" "." ".."))))
              (string-split path #\/))))

(define (paths-overlap? a b)
  (or (string=? a b)
      (string-prefix? (string-append a "/") b)
      (string-prefix? (string-append b "/") a)))
