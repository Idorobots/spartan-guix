(use-modules (guix channels)
             (guix ui)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "channels")

(define root (dirname (dirname (canonicalize-path (current-filename)))))
(define test-commit "0123456789abcdef0123456789abcdef01234567")
(define generated
  (let ((previous (getenv "SPARTAN_GUIX_COMMIT")))
    (dynamic-wind
      (lambda () (setenv "SPARTAN_GUIX_COMMIT" test-commit))
      (lambda ()
        (with-output-to-string
          (lambda ()
            (save-module-excursion
             (lambda ()
               (set-current-module (make-fresh-user-module))
               (load (string-append root "/ci/channels.scm")))))))
      (lambda ()
        (if previous
            (setenv "SPARTAN_GUIX_COMMIT" previous)
            (unsetenv "SPARTAN_GUIX_COMMIT"))))))
(define channels
  (load* (open-input-string generated)
         '(((guix channels) channel make-channel-introduction openpgp-fingerprint))
         #:isolated? #t))
(define spartan
  (find (lambda (value) (eq? (channel-name value) 'spartan-guix)) channels))
(define guix
  (find (lambda (value) (eq? (channel-name value) 'guix)) channels))

(test-equal "CI emits an isolated-loadable list without duplicating runtime dependencies"
  '(spartan-guix guix)
  (map channel-name channels))

(test-equal "CI selects the exact local checkout commit"
  (list (string-append "file://" root) test-commit)
  (list (channel-url spartan) (channel-commit spartan)))

(test-assert "CI pins Guix with its authentication introduction"
  (and (string? (channel-commit guix))
       (= 40 (string-length (channel-commit guix)))
       (channel-introduction? (channel-introduction guix))))

(define runner (test-runner-current))
(test-end "channels")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
