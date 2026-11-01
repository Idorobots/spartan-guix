(define-module (spartan packages avahi)
  #:use-module ((gnu packages guile-xyz) #:select (guile-avahi))
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (guile-avahi/without-daemon-tests))

(define guile-avahi/without-daemon-tests
  (package
    (inherit guile-avahi)
    (location (package-location guile-avahi))
    (arguments
     (substitute-keyword-arguments (package-arguments guile-avahi)
       ;; All seven tests in 0.4.1 create clients of an existing Avahi daemon
       ;; over system D-Bus, including the poll and error tests.  The suite
       ;; starts no private service and cannot run in an isolated builder.
       ((#:tests? _ #t) #f)))))
