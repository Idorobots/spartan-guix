(use-modules (guix build-system trivial)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (spartan packages mixed)
             (srfi srfi-1)
             (srfi srfi-64))

(define available? (@@ (spartan packages mixed) %native-outputs-available?))
(define (fixture name)
  (package
    (name name) (version "1") (source #f)
    (build-system trivial-build-system)
    (arguments (list #:builder #~(mkdir #$output)))
    (home-page "https://example.org") (synopsis "Gexp routing fixture")
    (description "Derivation-only native-first gexp routing fixture.") (license #f)))

(test-begin "native-first-gexps")

(with-store store
  (for-each
   (lambda (cross?)
     (for-each
      (lambda (child-hit?)
        (let* ((suffix (string-append (if cross? "cross" "native")
                                      (if child-hit? "-hit" "-miss")))
               (child (fixture (string-append "hidden-child-" suffix)))
               (fixed (package (inherit child)
                        (name (string-append "fixed-" (package-name child)))))
               (parent (package
                         (inherit (fixture (string-append "hidden-parent-" suffix)))
                         ;; Neither reference occurs in the declared input lists.
                         (arguments
                          (list #:builder
                                #~(begin #$(file-append child "/payload")
                                         #+child (mkdir #$output)))))))
          (parameterize ((available? (lambda (p candidate system)
                                       (and child-hit? (eq? p child)))))
            (call-with-values
                (lambda ()
                  (make-native-first-package-mapper
                   (lambda (p system) (if (eq? p child) fixed p))))
              (lambda (rewrite owns?)
                (let* ((selected (rewrite
                                  (if cross?
                                      (package-with-compilation-system
                                       parent #:system "x86_64-linux")
                                      parent)))
                       (drv (package-derivation store selected
                                                (if cross? "armhf-linux" "x86_64-linux")
                                                #:graft? #f))
                       (inputs (map derivation-input-path (derivation-inputs drv)))
                       (native (package-derivation store (if child-hit? child fixed)
                                                   "x86_64-linux" #:graft? #f))
                       (runtime (if cross?
                                    (package-cross-derivation store fixed
                                                              "arm-linux-gnueabihf"
                                                              "x86_64-linux" #:graft? #f)
                                    native)))
                  (test-assert (string-append suffix ": hidden runtime reference is routed")
                    (member (derivation-file-name runtime) inputs))
                  (test-assert (string-append suffix ": native reference uses its own context")
                    (member (derivation-file-name native) inputs))))))))
      '(#f #t)))
   '(#f #t))

  (test-assert "a native hit inside a fallback gexp retains its entire hidden graph"
    (let* ((leaf (fixture "hidden-retained-leaf"))
           (middle (package (inherit (fixture "hidden-retained-middle"))
                     (arguments (list #:builder #~(begin #$leaf (mkdir #$output))))))
           (root (package (inherit (fixture "hidden-retained-root"))
                   (arguments (list #:builder #~(begin #$middle (mkdir #$output))))))
           (fixed '()))
      (parameterize ((available? (lambda (p candidate system) (eq? p middle))))
        (call-with-values
            (lambda ()
              (make-native-first-package-mapper
               (lambda (p system)
                 (set! fixed (cons p fixed))
                 (if (eq? p leaf)
                     (package (inherit p) (name "unexpectedly-rewritten-leaf")) p))))
          (lambda (rewrite owns?)
            (let* ((drv (package-derivation store (rewrite root) "x86_64-linux" #:graft? #f))
                   (upstream (with-store original-store
                               (package-derivation original-store middle "x86_64-linux"
                                                   #:graft? #f))))
              (and (not (memq leaf fixed))
                   (member (derivation-file-name upstream)
                           (map derivation-input-path (derivation-inputs drv)))))))))))

(define runner (test-runner-current))
(test-end "native-first-gexps")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
