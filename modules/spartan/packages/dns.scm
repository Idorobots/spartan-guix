(define-module (spartan packages dns)
  #:use-module (gnu packages dns)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (isc-bind/cross-fixed))

(define isc-bind/cross-fixed
  (package
    (inherit isc-bind)
    (inputs
     (if (%current-target-system)
         ;; BIND 9.19.24 no longer ships the old isc Python module that used
         ;; PLY.  Only historical changelog entries mention it.  The stale
         ;; target input cannot be lowered with Guix's pyproject build system.
         (modify-inputs (package-inputs isc-bind)
           (delete "python-ply"))
         (package-inputs isc-bind)))))
