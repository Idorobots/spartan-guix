(define-module (spartan packages avahi)
  #:use-module ((gnu packages guile-xyz) #:select (guile-avahi))
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (guile-avahi/namespace-aware))

(define %foreign-interface-patch
  (canonicalize-path
   (or (search-path %load-path
                    "spartan/packages/patches/guile-avahi-foreign-interfaces.patch")
       (error "Guile-Avahi interface patch is missing"))))

(define guile-avahi/namespace-aware
  (package
    (inherit guile-avahi)
    (source
     (origin
       (inherit (package-source guile-avahi))
       (patches
        (append (origin-patches (package-source guile-avahi))
                (list %foreign-interface-patch)))))
    (arguments
     (substitute-keyword-arguments (package-arguments guile-avahi)
       ;; The publishing tests register 0.0.0.0 under different host names.
       ;; Concurrent reverse-PTR claims collide in a shared Avahi daemon.
       ((#:parallel-tests? _ #t) #f)))))
