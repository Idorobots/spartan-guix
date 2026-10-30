(use-modules (gnu packages dns)
             (guix build-system)
             (guix derivations)
             (guix packages)
             (guix store)
             (spartan packages dns)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "bind-cross")

(test-assert "cross BIND omits obsolete PLY but retains Python and both outputs"
  (let ((bag (package->bag isc-bind/cross-fixed
                           "x86_64-linux" "aarch64-linux-gnu")))
    (and (not (assoc-ref (bag-host-inputs bag) "python-ply"))
         (assoc-ref (bag-host-inputs bag) "python")
         (equal? (package-outputs isc-bind/cross-fixed) '("out" "utils"))
         (equal? (package-arguments isc-bind/cross-fixed)
                 (package-arguments isc-bind)))))

(test-assert "native x86 and AArch64 BIND retain upstream derivations"
  (with-store store
    (every (lambda (system)
             (string=?
              (derivation-file-name
               (package-derivation store isc-bind system #:graft? #f))
              (derivation-file-name
               (package-derivation store isc-bind/cross-fixed system #:graft? #f))))
           '("x86_64-linux" "aarch64-linux"))))

(test-assert "BIND cross derivation can be lowered without pyproject support"
  (with-store store
    (derivation? (package-cross-derivation
                  store isc-bind/cross-fixed "aarch64-linux-gnu"
                  "x86_64-linux" #:graft? #f))))

(define runner (test-runner-current))
(test-end "bind-cross")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
