(use-modules (gnu)
             (gnu bootloader grub)
             (gnu image)
             (gnu packages base)
             (gnu packages guile)
             (gnu packages pdf)
             (gnu packages flashing-tools)
             (gnu packages virtualization)
             (gnu system image)
             (guix build-system)
             (guix build-system trivial)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix monads)
             (guix packages)
             (guix store)
             (guix utils)
             (spartan packages build-fixes)
             (spartan packages mixed)
             (spartan system build-policy)
             (srfi srfi-1)
             (srfi srfi-64))

(define available? (@@ (spartan packages mixed) %native-outputs-available?))
(available? (const #f))
(use-modules (gnu system images raspberrypi))

(test-begin "build-policy")

(define* (fixture name #:optional (inputs '()))
  (package
    (name name) (version "1") (source #f)
    (build-system trivial-build-system)
    (inputs inputs)
    (arguments (list #:builder #~(mkdir #$output)))
    (home-page "https://example.org") (synopsis "Policy fixture")
    (description "Derivation-only build-policy fixture.") (license #f)))

(with-store store
  (define (drv p system)
    (package-derivation store p system #:graft? #f))
  (define (lower p system)
    (parameterize ((%graft? #f))
      (run-with-store store (lower-object p system #:target #f))))

  (for-each
   (lambda (already-selected?)
     (test-assert
         (string-append "active OS policy preserves a native hit's builder references"
                        (if already-selected? " (selected)" " (unselected)"))
       (let* ((suffix (if already-selected? "selected" "unselected"))
              (child (fixture (string-append "native-hit-gexp-child-" suffix)))
              (base (package
                      (inherit (fixture (string-append "native-hit-gexp-parent-" suffix)))
                      ;; This dependency exists only in the builder gexp.
                      (arguments (list #:builder #~(begin #$child (mkdir #$output))))))
              (policy (make-raspberry-pi-build-policy
                       #:mixed-packages (list base child)))
              (queries '()))
         (parameterize ((available? (lambda (p candidate system)
                                     (set! queries (cons (%active-build-policy) queries))
                                     (eq? p base))))
           (let* ((p (if already-selected? (build-policy-package policy base) base))
                  (selected (parameterize ((%active-build-policy policy))
                              (lower p "aarch64-linux")))
                  ;; Use a separate store cache: deriving the upstream graph
                  ;; first in STORE would hide the policy leak being tested.
                  (upstream (with-store original-store
                              (package-derivation original-store base "aarch64-linux"
                                                  #:graft? #f))))
             (and (pair? queries) (every not queries)
                  (string=? (derivation-file-name upstream)
                            (derivation-file-name selected))))))))
   '(#t #f))

  (test-assert "a native hit cuts off all fallback dependency transformations"
    (let* ((child (fixture "hit-child"))
           (base (fixture "hit-parent" (list child)))
           (calls '()) (queries '()))
      (parameterize ((available? (lambda (p candidate system)
                                  (set! queries (cons (package-name p) queries)) #t)))
        (call-with-values
            (lambda ()
              (make-native-first-package-mapper
               (lambda (p system) (set! calls (cons p calls)) p)))
          (lambda (rewrite owns?)
            (let ((p (rewrite base)))
              (and (null? queries) (null? calls)
                   (string=? (derivation-file-name (drv base "x86_64-linux"))
                             (derivation-file-name (drv p "x86_64-linux")))
                    (null? calls) (equal? queries '("hit-parent")))))))))

  (test-assert "OS policy lowering does not reuse a cached unselected service reference"
    (let* ((child (fixture "cached-os-service-child"))
           (reference (computed-file "cached-os-service-reference"
                        #~(begin #$(file-append child "/payload") (mkdir #$output))))
           (policy (make-raspberry-pi-build-policy #:mixed-packages (list child)))
           (upstream (lower reference "aarch64-linux"))
           (selected
            (parameterize ((%graft? #f))
              (run-with-store store
                ((@@ (spartan system build-policy) call-with-build-policy) policy
                 (lambda () (lower-object reference "aarch64-linux" #:target #f))))))
           (expected (package-cross-derivation store child "aarch64-linux-gnu"
                                                "x86_64-linux" #:graft? #f)))
      (and (member (derivation-file-name expected)
                   (map derivation-input-path (derivation-inputs selected)))
           (string=? (derivation-file-name upstream)
                     (derivation-file-name (lower reference "aarch64-linux"))))))

  (test-assert "a parent miss retains an available child without rewriting it"
    (let* ((child (fixture "retained-child"))
           (base (fixture "missing-parent" (list child))) (fixed '()))
      (parameterize ((available? (lambda (p candidate system) (eq? p child))))
        (call-with-values
            (lambda ()
              (make-native-first-package-mapper
               (lambda (p system)
                 (set! fixed (cons (package-name p) fixed))
                 (package (inherit p) (version "fixed")))))
          (lambda (rewrite owns?)
            (let ((selected (drv (rewrite base) "x86_64-linux")))
              (and (equal? fixed '("missing-parent"))
                   (member (derivation-file-name (drv child "x86_64-linux"))
                           (map derivation-input-path (derivation-inputs selected))))))))))

  (test-assert "mixed fallback checks the original recipe and rejects incompatible native library paths"
    (let* ((library (fixture "fallback-library"))
           (base (package (inherit (fixture "fallback-consumer"))
                   (propagated-inputs (list library))))
           (seen? #f))
      (parameterize
          ((available?
            (lambda (p candidate system)
              (if (eq? p base)
                  (begin
                    (set! seen? #t)
                    ((@@ (spartan packages mixed) native-candidate-usable?)
                     store p candidate system #:valid? (const #t)))
                  #f))))
        (call-with-values
            (lambda () (make-native-first-package-mapper (lambda (p system) p)))
          (lambda (rewrite owns?)
            (let* ((p (rewrite (package-with-compilation-system
                               base #:system "x86_64-linux")))
                   (bag (package->bag p "armhf-linux" #f #:graft? #f)))
              (and seen? (string=? "x86_64-linux" (bag-system bag))
                   (string=? "arm-linux-gnueabihf" (bag-target bag)))))))))

  (test-assert "implicit cross-build tools receive host fixes, not target fixes"
    (call-with-values
        (lambda ()
          (make-native-first-package-mapper
           (lambda (p system)
             (if (string=? (package-name p) "bash-minimal")
                 (package (inherit p) (name (string-append system "-shell")))
                 p))))
      (lambda (rewrite owns?)
        (let* ((p (rewrite (package-with-compilation-system hello #:system "x86_64-linux")))
               (bag (package->bag p "armhf-linux" #f #:graft? #f))
               (shell (find (lambda (input)
                              (and (package? (cadr input))
                                   (string=? (package-name (cadr input)) "bash-minimal")))
                            (bag-build-inputs bag))))
          (and shell
               (string-prefix? "x86_64-linux-shell-"
                               (bag-name (package->bag (cadr shell) "x86_64-linux" #f #:graft? #f))))))))

  (test-assert "native-first mixed fallbacks retain security replacements and their architecture"
    (let* ((security-package (fixture "security-replacement"))
           (base (package (inherit (fixture "security-original"))
                   (replacement security-package))))
      (call-with-values
          (lambda () (make-native-first-package-mapper (lambda (p system) p)))
        (lambda (rewrite owns?)
          (let* ((p (rewrite (package-with-compilation-system base #:system "x86_64-linux")))
                 (bag (package->bag p "armhf-linux" #f #:graft? #t)))
            (and (string-prefix? "security-replacement-" (bag-name bag))
                 (string=? "x86_64-linux" (bag-system bag))
                 (string=? "arm-linux-gnueabihf" (bag-target bag))))))))

  (test-assert "importing Pi policies leaves unopted-in native packages unchanged"
    (and (eq? genimage (@ (gnu packages flashing-tools) genimage))
         (eq? qemu-minimal (@ (gnu packages virtualization) qemu-minimal))
         (string=? (derivation-file-name (drv hello "x86_64-linux"))
                   (derivation-file-name (lower hello "x86_64-linux")))))

  (test-assert "Poppler's fallback retains labelled inputs when adding native gettext"
    (let ((fixed (package-build-fix poppler "x86_64-linux")))
      (and (lookup-package-native-input fixed "gettext")
           (lookup-package-native-input fixed "pkg-config")
           (bag? (package->bag fixed "x86_64-linux" #f #:graft? #f)))))

  (for-each
   (lambda (system cortex?)
     (let* ((marked (fixture (string-append "marked-" system (if cortex? "-a53" ""))))
            (ordinary (fixture (string-append "ordinary-" system)))
            (policy (make-raspberry-pi-build-policy
                     #:system system #:build-system "x86_64-linux"
                     #:cortex-a53? cortex? #:mixed-packages (list marked))))
       (test-assert (string-append system (if cortex? " A53" "") ": selective cross fallback")
         (let ((normal (package->bag (build-policy-package policy ordinary) system #f))
               (mixed (package->bag (build-policy-package policy marked) system #f)))
           (and (string=? system (bag-system normal)) (not (bag-target normal))
                (string=? "x86_64-linux" (bag-system mixed))
                (string=? (if (string=? system "armhf-linux")
                              "arm-linux-gnueabihf" "aarch64-linux-gnu")
                          (bag-target mixed)))))
       (test-assert (string-append system ": image tools query only their host architecture")
         (let ((systems '()))
           (parameterize ((available? (lambda (p candidate system)
                                       (set! systems (cons system systems)) #t)))
             (let ((tool (build-policy-package policy genimage #:role 'build)))
               (and (string=? (derivation-file-name (drv genimage "x86_64-linux"))
                             (derivation-file-name (drv tool "x86_64-linux")))
                    (pair? systems) (every (lambda (s) (string=? s "x86_64-linux")) systems))))))
       (test-equal (string-append system (if cortex? " A53" "")
                                 ": substitutes cannot bypass a required runtime fix")
         cortex?
         (parameterize ((available? (const #t)))
           (let ((fresh (make-raspberry-pi-build-policy
                         #:system system #:build-system "x86_64-linux"
                         #:cortex-a53? cortex?)))
             (not (string=?
                   (derivation-file-name (drv guile-3.0 system))
                   (derivation-file-name
                    (drv (build-policy-package fresh guile-3.0) system)))))))
       (test-assert (string-append system ": same-platform marked requests stay native")
         (let* ((native (make-raspberry-pi-build-policy
                         #:system system #:build-system system
                         #:cortex-a53? cortex? #:mixed-packages (list marked)))
                (bag (package->bag (build-policy-package native marked) system #f)))
           (and (string=? system (bag-system bag)) (not (bag-target bag)))))))
   '("armhf-linux" "aarch64-linux" "aarch64-linux") '(#f #t #f)))

(define runner (test-runner-current))
(test-end "build-policy")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
