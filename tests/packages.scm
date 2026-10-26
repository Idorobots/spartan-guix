(use-modules (gnu packages file-systems)
             (guix packages)
             (spartan packages file-systems)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "packages")

(test-equal "bcachefs workaround preserves native build inputs"
  (package-native-inputs bcachefs-tools)
  (package-native-inputs bcachefs-tools/cross-fixed))

(test-assert "bcachefs tools retain a labelled native helper when cross-compiling"
  (let* ((bag (package->bag bcachefs-tools/cross-fixed
                            "x86_64-linux" "aarch64-linux-gnu" #:graft? #f))
         (inputs (bag-transitive-build-inputs bag)))
    (and (every (lambda (input)
                  (and (pair? input) (string? (car input))))
                inputs)
         (find (lambda (input)
                 (and (string=? "bcachefs-tools-minimal" (car input))
                      (package? (cadr input))))
               inputs))))

(define runner (test-runner-current))
(test-end "packages")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
