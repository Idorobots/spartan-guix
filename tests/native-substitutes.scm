(use-modules (gnu packages base)
             (gnu packages guile)
             (guix build-system)
             (guix build-system trivial)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix monads)
             (guix packages)
             (guix profiles)
             (guix store)
             (guix utils)
             (spartan packages guile)
             (spartan packages mixed)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "native-substitutes")

(define available? (@@ (spartan packages mixed) %native-outputs-available?))
(define outputs-available? (@@ (spartan packages mixed) native-outputs-available?))
(define candidate-usable? (@@ (spartan packages mixed) native-candidate-usable?))
(define* (fixture name #:optional (propagated '()))
  (package
    (name name) (version "1") (source #f)
    (build-system trivial-build-system)
    (arguments (list #:builder
                     #~(for-each (lambda (output) (mkdir (cdr output))) %outputs)))
    (outputs '("out" "debug"))
    (propagated-inputs propagated)
    (home-page "https://example.org") (synopsis "Substitute routing fixture")
    (description "A derivation-only fixture; no package builds are needed.")
    (license #f)))

(define (bag-for p) (package->bag p "aarch64-linux" #f #:graft? #f))

(with-store store
  (define base (fixture "native-substitute-outputs"))
  (define (drv p) (package-derivation store p "aarch64-linux" #:graft? #f))
  (define paths
    (map (lambda (output) (derivation-output-path (cdr output)))
         (derivation-outputs (drv base))))

  (define (collision-free? packages)
    (parameterize ((%current-system "aarch64-linux")
                   (%current-target-system #f) (%graft? #f))
      (run-with-store store
        (check-for-collisions (packages->manifest packages) "aarch64-linux"))))

  (test-assert "query all exact native outputs together, including debug"
    (let ((seen #f))
      (and (outputs-available? store base "aarch64-linux"
                              #:valid? (const #f)
                              #:substitutes (lambda (store paths) (set! seen paths) paths))
           (lset= string=? seen paths)
           (= 2 (length seen)))))

  (test-assert "a missing debug substitute keeps the cross fallback eligible"
    (not (outputs-available?
          store base "aarch64-linux" #:valid? (const #f)
          #:substitutes (lambda (store paths)
                          (remove (lambda (path) (string-suffix? "-debug" path)) paths)))))

  (test-assert "local outputs skip substitute queries"
    (outputs-available? store base "aarch64-linux" #:valid? (const #t)
                        #:substitutes (lambda args (error "unexpected query"))))

  (test-assert "local and remote outputs can satisfy the same package"
    (let ((seen #f) (local (car paths)))
      (and (outputs-available? store base "aarch64-linux"
                              #:valid? (lambda (store path) (string=? local path))
                              #:substitutes (lambda (store paths) (set! seen paths) paths))
           (= 1 (length seen)) (not (member local seen)))))

  (test-assert "substitution-disabled recipes accept only local outputs"
    (let ((p (package (inherit hello)
                      (arguments (list #:substitutable? #f)))))
      (and (not (outputs-available? store p "aarch64-linux" #:valid? (const #f)
                                    #:substitutes (lambda args (error "unexpected query"))))
           (outputs-available? store p "aarch64-linux" #:valid? (const #t)
                               #:substitutes (lambda args (error "unexpected query"))))))

  (test-error "query failures propagate instead of being recorded as misses"
    #t
    (outputs-available? store base "aarch64-linux" #:valid? (const #f)
                        #:substitutes (lambda args (error "query failed"))))

  (test-assert "selection is lazy, memoized and native on a hit, with exact original outputs"
    (let ((queries 0) (p (fixture "native-substitute-hit")))
      (parameterize ((available? (lambda (p candidate system) (set! queries (+ 1 queries)) #t)))
        (let ((selected (package-with-compilation-system p #:system "x86_64-linux")))
          (and (zero? queries)
               (string=? "aarch64-linux" (bag-system (bag-for selected)))
               (not (bag-target (bag-for selected)))
               (= 1 queries)
               (string=? (derivation-file-name (drv p))
                         (derivation-file-name (drv selected)))
               (= 1 queries))))))

  (test-assert "a miss uses the existing direct cross derivation without copies"
    (let ((p (fixture "native-substitute-miss")))
      (parameterize ((available? (const #f)))
        (let ((selected (package-with-compilation-system p #:system "x86_64-linux")))
          (and (string=? "x86_64-linux" (bag-system (bag-for selected)))
               (string=? "aarch64-linux-gnu" (bag-target (bag-for selected)))
               (string=? (derivation-file-name (drv selected))
                         (derivation-file-name
                          (package-cross-derivation store p "aarch64-linux-gnu"
                                                    "x86_64-linux" #:graft? #f))))))))

  (test-assert "the original native candidate and routed candidate both reach the availability check"
    (let* ((library (fixture "native-original-library"))
           (base (fixture "native-original-consumer" (list library)))
           (checked #f))
      (parameterize ((available? (lambda (p candidate system)
                                   (when (eq? p base)
                                     (set! checked candidate))
                                   #f)))
        (let ((selected (package-with-compilation-system base #:system "x86_64-linux")))
          (bag-for selected)
          (and checked (not (eq? base checked))
               (string=? "x86_64-linux" (bag-system (bag-for selected))))))))

  (test-assert "native substitutes are rejected when propagated library paths differ"
    (let* ((library (fixture "native-compatibility-library"))
           (base (fixture "native-compatibility-consumer" (list library)))
           (candidate (package
                        (inherit base)
                        (propagated-inputs
                         (list (package-with-compilation-system
                                library #:system "x86_64-linux"))))))
      (parameterize ((available? (const #f)))
        (and (not (candidate-usable? store base candidate "aarch64-linux"
                                    #:valid? (const #t)))
             (candidate-usable? store base base "aarch64-linux" #:valid? (const #t))))))

  (test-assert "native build tools and same-platform requests do not query substitutes"
    (let ((p (fixture "native-substitute-tool")))
      (parameterize ((available? (lambda args (error "unexpected query"))))
        (let ((tool (package->bag
                     (package-with-compilation-system p #:system "x86_64-linux")
                     "x86_64-linux" #f))
              (native (bag-for
                       (package-with-compilation-system p #:system "aarch64-linux"))))
          (and (string=? "x86_64-linux" (bag-system tool)) (not (bag-target tool))
               (string=? "aarch64-linux" (bag-system native)) (not (bag-target native)))))))

  (for-each
   (lambda (native-library?)
     (test-assert (if native-library?
                      "native and cross consumers share native propagated libraries in bags and profiles"
                      "native and cross consumers share cross propagated libraries in bags and profiles")
       (let* ((suffix (if native-library? "native" "cross"))
              (library (fixture (string-append "shared-library-" suffix)))
              (native (fixture (string-append "native-consumer-" suffix) (list library)))
              (cross (fixture (string-append "cross-consumer-" suffix) (list library))))
         (parameterize ((available?
                         (lambda (p candidate system)
                           (cond ((string-prefix? "native-consumer" (package-name p)) #t)
                                 ((string-prefix? "cross-consumer" (package-name p)) #f)
                                 (else native-library?)))))
           (let* ((native (package-with-compilation-system native #:system "x86_64-linux"))
                  (cross (package-with-compilation-system cross #:system "x86_64-linux"))
                  (lib (package-with-compilation-system library #:system "x86_64-linux"))
                  (lib-drv (drv lib)))
             (and (string=? "aarch64-linux" (bag-system (bag-for native)))
                  (string=? "x86_64-linux" (bag-system (bag-for cross)))
                  (every (lambda (p)
                           (member (derivation-file-name lib-drv)
                                   (map derivation-input-path (derivation-inputs (drv p)))))
                         (list native cross))
                  (collision-free? (list native cross))))))))
   '(#t #f))

  (for-each
   (lambda (choices)
     (test-assert (string-append "Guile/Readline profiles stay coherent with native choices "
                                 (object->string choices))
       ;; A fresh recipe transformation gives each case independent package
       ;; identities; library choices remain shared, just as in one invocation.
       (let* ((rewrite (make-guile-runtime-rewriter
                        #:system "x86_64-linux"
                        #:guile-transform (lambda (p) (package (inherit p)))))
              (bases (list guile-3.0 guile-3.0-latest guile-readline)))
         (parameterize ((available?
                         (lambda (p candidate system)
                           (cond ((string=? "guile" (package-name p))
                                  (if (string=? (package-version p) (package-version guile-3.0))
                                      (car choices) (cadr choices)))
                                 ((string=? "guile-readline" (package-name p)) (caddr choices))
                                 (else #t)))))
           (let ((selected (map rewrite bases)))
             (and (every (lambda (p native?)
                           (string=? (if native? "aarch64-linux" "x86_64-linux")
                                     (bag-system (bag-for p))))
                         selected choices)
                  ;; Separate profiles: two Guile versions themselves cannot
                  ;; coexist as direct entries, regardless of compilation mode.
                  (collision-free? (list (car selected) (caddr selected)))
                  (collision-free? (list (cadr selected) (caddr selected)))))))))
   '((#t #f #t) (#f #t #f) (#f #f #t) (#t #t #f))))

(define runner (test-runner-current))
(test-end "native-substitutes")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
