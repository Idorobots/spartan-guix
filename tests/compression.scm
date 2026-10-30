(use-modules (gnu packages check)
             (gnu packages compression)
             (gnu packages ssh)
             (guix build-system)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (guix utils)
             (spartan packages compression)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "libcbor-cross")

(test-assert "cross test executables link target CMocka, not native CMocka"
  (let ((bag (package->bag libcbor/cross-fixed
                           "x86_64-linux" "aarch64-linux-gnu")))
    (and (equal? (assoc-ref (bag-host-inputs bag) "cmocka") (list cmocka))
         (not (assoc-ref (bag-build-inputs bag) "cmocka")))))

(test-assert "upstream test compilation and shared-library flags are retained"
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "aarch64-linux-gnu"))
    (let* ((arguments (package-arguments libcbor/cross-fixed))
           (flags (apply (lambda* (#:key configure-flags #:allow-other-keys)
                           configure-flags)
                         arguments))
           (flags (eval (gexp->approximate-sexp flags) (current-module))))
      (and (member "-DWITH_TESTS=ON" flags)
           (member "-DBUILD_SHARED_LIBS=ON" flags)))))

(test-assert "native x86 and AArch64 derivations remain identical to upstream"
  (with-store store
    (every (lambda (system)
             (string=?
              (derivation-file-name
               (package-derivation store libcbor system #:graft? #f))
              (derivation-file-name
               (package-derivation store libcbor/cross-fixed system #:graft? #f))))
           '("x86_64-linux" "aarch64-linux"))))

(test-assert "OpenSSH's transitive libcbor dependency selects the cross fix"
  (parameterize ((%current-target-system "aarch64-linux-gnu"))
    (let* ((ssh (package-with-cross-fixed-libcbor openssh))
           (fido (lookup-package-input ssh "libfido2")))
      (eq? (lookup-package-input fido "libcbor") libcbor/cross-fixed))))

(define runner (test-runner-current))
(test-end "libcbor-cross")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
