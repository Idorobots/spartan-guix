(define-module (spartan packages guile)
  #:use-module ((gnu packages admin) #:select (shepherd-0.10 shepherd-1.0))
  #:use-module (gnu packages guile)
  #:use-module ((gnu packages guile-xyz) #:select (guile-avahi))
  #:use-module ((gnu packages package-management) #:select (guix))
  #:use-module (gnu packages pkg-config)
  #:use-module ((gnu packages ssh) #:select (guile-ssh))
  #:use-module (guix build-system gnu)
  #:use-module ((guix config) #:select (%system))
  #:use-module (guix gexp)
  #:use-module (guix memoization)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (spartan packages avahi)
  #:use-module (spartan packages mixed)
  #:export (guile-3.0/cortex-a53
            guile-3.0-latest/cortex-a53
            package-with-cortex-a53-guile))

(define (guile-with-cortex-a53-fix base)
  ;; Erratum 843419 can corrupt a load in compiled C code in libguile when
  ;; an ADRP sequence straddles a 4 KiB boundary.  This is a link-time fix;
  ;; it does not change code generated later by Guile's JIT.
  (package
    (inherit base)
    (arguments
     (if (target-aarch64?)
         (substitute-keyword-arguments (package-arguments base)
           ((#:configure-flags flags #~'())
            #~(begin
                (use-modules (srfi srfi-1))
                (let* ((flags #$flags)
                       (ldflags? (lambda (flag)
                                   (string-prefix? "LDFLAGS=" flag)))
                       (previous (find ldflags? flags)))
                  (cons (string-append
                         (or previous "LDFLAGS=")
                         " -Wl,--fix-cortex-a53-843419")
                        (remove ldflags? flags)))))
           ((#:phases phases #~%standard-phases)
            (if (%current-target-system)
                (let ((sdk-pkg-config
                       (package-with-compilation-system
                        ;; pkg-config is identifier syntax that would select
                        ;; the build-machine cross wrapper in this context.
                        %pkg-config
                        #:system (gnu-triplet->nix-system
                                  (%current-target-system)))))
                  #~(modify-phases #$phases
                      (add-after 'install 'use-native-sdk-pkg-config
                        (lambda* (#:key outputs #:allow-other-keys)
                          ;; Upstream embeds the build-machine cross wrapper,
                          ;; an x86 executable in an AArch64 Guile installation.
                          (substitute* (string-append (assoc-ref outputs "out")
                                                      "/bin/guile-config")
                            (("\\(define %pkg-config-program \"[^\"]*\"\\)")
                             (string-append
                              "(define %pkg-config-program \""
                              #$(file-append sdk-pkg-config "/bin/pkg-config")
                              "\")")))))))
                phases)))
         (package-arguments base)))))

(define (native-guile-consumer-arguments base)
  (let ((arguments (package-arguments base)))
    (if (and (target-aarch64?)
             (not (%current-target-system))
             (eq? (package-build-system base) gnu-build-system))
        (substitute-keyword-arguments arguments
          ((#:phases phases #~%standard-phases)
           #~(modify-phases #$phases
               (add-after 'set-paths 'set-native-guile-preprocessor
                 (lambda _
                   ;; guile-snarf retains Guile's configure-time cross CPP.
                   ;; Export the consumer's compiler instead.  Configure's
                   ;; Makefile CPP variable alone is not exported to scripts.
                   (let ((cpp (getenv "CPP")))
                     (unless (and cpp (not (string-null? cpp)))
                       (setenv "CPP"
                               (string-append (or (getenv "CC")
                                                  #$(cc-for-target))
                                              " -E")))))))))
        arguments)))

;; Preserve the upstream versions: the default service interpreter and the
;; interactive interpreter need not be the same Guile release.
(define guile-3.0/cortex-a53
  (package-with-compilation-system (guile-with-cortex-a53-fix guile-3.0)))

(define guile-3.0-latest/cortex-a53
  (package-with-compilation-system (guile-with-cortex-a53-fix guile-3.0-latest)))

(define cortex-a53-guile-rewriter
  (memoize
   (lambda (system)
     (define replacements
       (if (string=? system (gnu-triplet->nix-system %system))
           `((,guile-3.0 . ,guile-3.0/cortex-a53)
             (,guile-3.0-latest . ,guile-3.0-latest/cortex-a53))
           `((,guile-3.0
              . ,(package-with-compilation-system
                  (guile-with-cortex-a53-fix guile-3.0) #:system system))
             (,guile-3.0-latest
              . ,(package-with-compilation-system
                  (guile-with-cortex-a53-fix guile-3.0-latest) #:system system)))))

     (define (rewrite-input input)
       (match input
         ((label (? package? p) outputs ...)
          (let ((selected (rewrite p)))
            (if (eq? selected p) input (cons* label selected outputs))))
         (_ input)))

     (define (rewrite-native-guile input)
       ;; In a native consumer, native inputs precede runtime inputs in PATH
       ;; and PKG_CONFIG_PATH.  A duplicate upstream Guile would silently win
       ;; configure's interpreter and libguile discovery.  Rewrite this direct
       ;; duplicate, without descending into unrelated build tools.
       (match input
         ((label (? package? p) outputs ...)
          (let ((selected (assq-ref replacements p)))
            (if selected (cons* label selected outputs) input)))
         (_ input)))

     (define rewrite
       (mlambdaq (p)
         ;; Finish recipe changes before wrapping: the adapter delegates to
         ;; this underlying package, re-evaluating it in the build context.
         (let ((selected (rewrite-package p)))
           (if (memq p (list guix shepherd-0.10 shepherd-1.0
                             guile-ssh guile-readline))
               (package-with-compilation-system selected #:system system)
               selected))))

     (define (rewrite-package p)
       (or (assq-ref replacements p)
           (let* ((p (if (eq? p guile-avahi) guile-avahi/namespace-aware p))
                  (original-inputs (package-inputs p))
                  (propagated (package-propagated-inputs p))
                  (original-replacement (package-replacement p))
                  (inputs* (map rewrite-input original-inputs))
                  (propagated* (map rewrite-input propagated))
                  (replacement* (and original-replacement
                                     (rewrite original-replacement))))
             (if (and (equal? original-inputs inputs*)
                      (equal? propagated propagated*)
                      (eq? original-replacement replacement*))
                 p
                 (package
                   (inherit p)
                   (location (package-location p))
                   (arguments (native-guile-consumer-arguments p))
                   (inputs (map rewrite-input (package-inputs p)))
                   (native-inputs
                    ;; Cross builds need upstream build-machine Guile;
                    ;; native consumers must align duplicate Guile inputs.
                    (if (%current-target-system)
                        (package-native-inputs p)
                        (map rewrite-native-guile (package-native-inputs p))))
                   (propagated-inputs
                    (map rewrite-input (package-propagated-inputs p)))
                   (replacement
                    (and=> (package-replacement p) rewrite)))))))
     rewrite)))

(define* (package-with-cortex-a53-guile package #:key (system %system))
  "Rewrite explicit runtime Guile dependencies for an AArch64 graph.
Selected Guile packages, Guix, Shepherd, Guile-SSH and Guile-Readline compile on
SYSTEM (the runner's native platform by default).  Unaffected packages and
unrelated build tools remain upstream.  Duplicate native Guile inputs of native
consumers use the same replacement."
  ;; Inspect the intended runtime graph even when an x86 runner loads this
  ;; module before --system takes effect.  Input rewriting remains deferred.
  (parameterize ((%current-system "aarch64-linux")
                 (%current-target-system #f))
    ((cortex-a53-guile-rewriter (gnu-triplet->nix-system system)) package)))
