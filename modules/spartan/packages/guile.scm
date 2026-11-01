(define-module (spartan packages guile)
  #:use-module ((gnu packages admin) #:select (shepherd-0.10 shepherd-1.0))
  #:use-module (gnu packages guile)
  #:use-module ((gnu packages package-management) #:select (guix))
  #:use-module ((gnu packages ssh) #:select (guile-ssh))
  #:use-module ((guix config) #:select (%system))
  #:use-module (guix memoization)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (spartan packages mixed)
  #:export (make-guile-runtime-rewriter))

(define %selective-consumers
  (list guix shepherd-0.10 shepherd-1.0 guile-ssh guile-readline))

(define make-guile-runtime-rewriter
  (memoize
   (lambda* (#:key (guile-transform identity) (replacements '()) (system %system))
     "Return an AArch64 runtime rewriter compiling selected packages on SYSTEM.
Apply GUILE-TRANSFORM to each upstream Guile recipe before adaptation.  Apply
REPLACEMENTS as recipe variants, rewriting their runtime dependencies too.
No hardware or SDK fixes are enabled by default.  Native cross-build tools
remain upstream; duplicate Guile inputs of native consumers are aligned."
     (let ((system (gnu-triplet->nix-system system)))
       (define guiles
         (map (lambda (base)
                (cons base (package-with-compilation-system
                            (guile-transform base) #:system system)))
              (list guile-3.0 guile-3.0-latest)))

       (define (rewrite-input input)
         (match input
           ((label (? package? p) outputs ...)
            (let ((selected (rewrite p)))
              (if (eq? selected p) input (cons* label selected outputs))))
           (_ input)))

       (define (rewrite-native-guile input)
         ;; Native inputs precede runtime inputs in PATH/PKG_CONFIG_PATH.
         ;; Align direct duplicates without descending into build-only tools.
         (match input
           ((label (? package? p) outputs ...)
            (let ((selected (assq-ref guiles p)))
              (if selected (cons* label selected outputs) input)))
           (_ input)))

       (define rewrite
         (mlambdaq (p)
           ;; Adapt only after recipe rewriting: the adapter delegates to the
           ;; underlying recipe and re-evaluates it in the build context.
           (let ((selected (rewrite-package p)))
             (if (memq p %selective-consumers)
                 (package-with-compilation-system selected #:system system)
                 selected))))

       (define (rewrite-package p)
         (or (assq-ref guiles p)
             (let* ((p (or (assq-ref replacements p) p))
                    (original-inputs (package-inputs p))
                    (propagated (package-propagated-inputs p))
                    (original-replacement (package-replacement p)))
               (if (and (equal? original-inputs (map rewrite-input original-inputs))
                        (equal? propagated (map rewrite-input propagated))
                        (eq? original-replacement
                             (and original-replacement (rewrite original-replacement))))
                   p
                   (package
                     (inherit p)
                     (location (package-location p))
                     ;; Keep fields deferred: the eventual native/cross context
                     ;; can select different upstream inputs and arguments.
                     (inputs (map rewrite-input (package-inputs p)))
                     (native-inputs
                      (if (%current-target-system)
                          (package-native-inputs p)
                          (map rewrite-native-guile (package-native-inputs p))))
                     (propagated-inputs
                      (map rewrite-input (package-propagated-inputs p)))
                     (replacement
                      (and=> (package-replacement p) rewrite)))))))

       (lambda (package)
         ;; Inspect the intended runtime graph even on an x86 image runner.
         ;; Input selection in the resulting recipes remains deferred.
         (parameterize ((%current-system "aarch64-linux")
                        (%current-target-system #f))
           (rewrite package)))))))
