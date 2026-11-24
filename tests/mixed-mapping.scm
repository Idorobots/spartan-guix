(use-modules (gnu packages base)
             (guix build-system)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (guix utils)
             (spartan packages mixed)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "mixed-mapping")
((@@ (spartan packages mixed) %native-outputs-available?) (const #f))

(define (fix base)
  (if (string=? (package-name base) "hello")
      (package
        (inherit base)
        (arguments
         (substitute-keyword-arguments (package-arguments base)
           ((#:configure-flags flags #~'()) #~(cons "CFLAGS=-O0" #$flags)))))
      base))
(define rewrite (make-compilation-package-mapper fix))
(define adapted (package-with-compilation-system hello #:system "x86_64-linux"))
(define parent
  (package (inherit hello) (name "mixed-mapper-parent")
           (inputs (list adapted)) (propagated-inputs (list adapted))))
(define selected
  (rewrite (package-with-compilation-system parent #:system "x86_64-linux")))
(define recipe
  (car (hashq-ref (@@ (spartan packages mixed) %compilation-packages) selected)))
(define dependency (lookup-package-input recipe "hello"))

(test-assert "recursive mapping retains outer and nested compilation adapters"
  (every (lambda (p) (hashq-ref (@@ (spartan packages mixed) %compilation-packages) p))
         (list selected dependency)))
(test-assert "rewritten adapters retain their original compilation platform"
  (every (lambda (p)
           (let ((bag (package->bag p "armhf-linux" #f)))
             (and (string=? "x86_64-linux" (bag-system bag))
                  (string=? "arm-linux-gnueabihf" (bag-target bag)))))
         (list selected dependency)))

(with-store store
  (define (drv p) (package-derivation store p "armhf-linux" #:graft? #f))
  (define expected
    (package-cross-derivation store (fix hello) "arm-linux-gnueabihf"
                              "x86_64-linux" #:graft? #f))
  (test-equal "nested recipe fixes reach the actual cross-build derivation"
    (derivation-file-name expected) (derivation-file-name (drv dependency)))
  (test-assert "the original unpatched dependency is absent from the parent inputs"
    (let ((inputs (map derivation-input-path (derivation-inputs (drv selected)))))
      (and (member (derivation-file-name expected) inputs)
           (not (member (derivation-file-name (drv adapted)) inputs)))))
  (test-equal "reapplying a mapper does not stack recipe fixes"
    (derivation-file-name (drv selected))
    (derivation-file-name (drv (rewrite selected)))))

(test-assert "deep mapping also visits implicit build inputs inside an adapter"
  (let* ((rewrite (make-compilation-package-mapper
                   (lambda (p)
                     (if (string=? (package-name p) "bash-minimal")
                         (package (inherit p) (name "mapper-bash")) p))))
         (bag (package->bag (rewrite adapted) "armhf-linux" #f)))
    (any (lambda (input) (and (package? (cadr input))
                              (string=? "mapper-bash" (package-name (cadr input)))))
         (bag-build-inputs bag))))

(define runner (test-runner-current))
(test-end "mixed-mapping")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
