(use-modules ((gnu packages base) #:select (hello))
             (gnu packages guile)
             ((gnu packages guile-xyz) #:select (guile-avahi))
             ((guix build gnu-build-system) #:prefix build:)
             (guix build-system)
             (guix build utils)
             (guix gexp)
             (guix packages)
             (guix utils)
             (ice-9 popen)
             (ice-9 textual-ports)
             (spartan packages avahi)
             (spartan packages guile)
             (spartan packages guile-config)
             (spartan packages guile-snarf)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "native-guile-tools")

(define %standard-phases build:%standard-phases)
(define %snarf-fixture
  (string-append (dirname (current-filename)) "/runtime/guile-snarf.in"))

(define (phases package system target)
  (parameterize ((%current-system system) (%current-target-system target))
    (let ((phases (apply (lambda* (#:key phases #:allow-other-keys) phases)
                         (package-arguments package))))
      (eval (gexp->approximate-sexp phases) (current-module)))))

;; A tiny install recipe lets the actual SDK phase edit and execute a script
;; fixture without rebuilding Guile or compiling a C extension.
(define snarf-base
  (package
    (inherit guile-3.0)
    (arguments (list #:phases #~(list (cons 'install (lambda _ #t)))))))
(define snarf (guile-with-native-snarf snarf-base))
(define prepare
  (assq-ref (phases snarf "x86_64-linux" "aarch64-linux-gnu")
            'use-native-sdk-preprocessor))

(test-assert "snarf correction is cross-only and preserves the install phase"
  (and prepare
       (assq-ref (phases snarf "x86_64-linux" "aarch64-linux-gnu") 'install)
       (not (assq-ref (phases snarf "aarch64-linux" #f)
                      'use-native-sdk-preprocessor))))

(call-with-temporary-directory
 (lambda (directory)
   (let* ((bin (string-append directory "/bin"))
          (script (string-append bin "/guile-snarf"))
          (shell (which "sh")))
     (define (run-snarf cpp cc)
       (with-environment-variables `(("CPP" ,cpp) ("CC" ,cc) ("PATH" ,bin))
         (let* ((pipe (open-pipe* OPEN_READ shell script "-DPROBE" "input.c"))
                (result (get-string-all pipe))
                (status (close-pipe pipe)))
           (unless (zero? status) (error "snarf subprocess failed" status))
           result)))
     (mkdir-p bin)
     (copy-file %snarf-fixture script)
     (prepare #:outputs `(("out" . ,directory)))
     (for-each
      (lambda (name)
        (let ((file (string-append bin "/" name)))
          (call-with-output-file file
            (lambda (port)
              (format port "#!~a\nprintf '%s\\n' ~s \"$@\"\n" shell name)))
          (chmod file #o755)))
      '("gcc" "custom-cc" "explicit-cpp"))
     (test-equal "snarf defaults to native gcc without an exported CPP"
       "gcc\n-E\n-DPROBE\ninput.c\n" (run-snarf #f #f))
     (test-equal "snarf honors the consumer's compiler and flags"
       "custom-cc\n--target=aarch64-linux-gnu\n-E\n-DPROBE\ninput.c\n"
       (run-snarf #f "custom-cc --target=aarch64-linux-gnu"))
     (test-equal "an explicit preprocessor takes precedence over CC"
       "explicit-cpp\n-DCUSTOM\n-DPROBE\ninput.c\n"
       (run-snarf "explicit-cpp -DCUSTOM" "custom-cc"))
     (test-equal "empty CPP and CC use the native default"
       "gcc\n-E\n-DPROBE\ninput.c\n" (run-snarf "" "")))))

(define sdk-fixes (compose guile-with-native-snarf guile-with-native-config))
(define sdk-package (make-guile-runtime-rewriter #:guile-transform sdk-fixes))
(define plain-package (make-guile-runtime-rewriter))

(test-assert "runtime rewriting leaves consumer arguments untouched"
  (let* ((consumer (package (inherit hello) (inputs (list guile-3.0))))
         (selected (sdk-package consumer)))
    (parameterize ((%current-system "aarch64-linux") (%current-target-system #f))
      (equal? (package-arguments consumer) (package-arguments selected)))))

(test-assert "SDK-only mixed compilation has no Cortex-A53 linker workaround"
  (every
   (lambda (base)
     (every
      (lambda (system)
        (let ((target (and (not (string=? system "aarch64-linux"))
                           "aarch64-linux-gnu")))
          (parameterize ((%current-system system) (%current-target-system target))
            (let* ((rewrite (make-guile-runtime-rewriter
                             #:guile-transform sdk-fixes #:system system))
                   (selected (rewrite base))
                   (bag (package->bag selected "aarch64-linux" #f))
                   (flags (apply (lambda* (#:key configure-flags #:allow-other-keys)
                                   configure-flags)
                                 (package-arguments selected)))
                   (flags (eval (gexp->approximate-sexp flags) (current-module))))
              (and (not (any (lambda (flag) (string-contains flag "fix-cortex-a53")) flags))
                   (string=? system (bag-system bag))
                   (equal? target (bag-target bag)))))))
      '("x86_64-linux" "aarch64-linux")))
   (list guile-3.0 guile-3.0-latest)))

(test-assert "config correction independently selects destination-native pkg-config"
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "aarch64-linux-gnu"))
    (every
     (lambda (base)
       (let* ((guile (guile-with-native-config base))
              (phases (apply (lambda* (#:key phases #:allow-other-keys) phases)
                             (package-arguments guile)))
              (pkg (any
                    (lambda (input)
                      (let* ((thing (gexp-input-thing input))
                             (base (and (file-append? thing) (file-append-base thing))))
                        (and (package? base)
                             (string=? "pkg-config" (package-name base))
                             base)))
                    ((@@ (guix gexp) gexp-inputs) phases)))
              (bag (and pkg (package->bag pkg "x86_64-linux" "aarch64-linux-gnu"))))
         (and bag (string=? "aarch64-linux" (bag-system bag))
              (not (bag-target bag)))))
     (list guile-3.0 guile-3.0-latest))))

(test-assert "unconfigured runtime rewriting enables no SDK or Avahi fixes"
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "aarch64-linux-gnu"))
    (and (equal? (package-arguments guile-3.0)
                 (package-arguments (plain-package guile-3.0)))
         (eq? (package-source guile-avahi)
              (package-source (plain-package guile-avahi))))))

(test-assert "Avahi is independently selectable and still receives SDK-only Guile"
  (let* ((rewrite (make-guile-runtime-rewriter
                   #:guile-transform sdk-fixes
                   #:replacements `((,guile-avahi . ,guile-avahi/namespace-aware))))
         (p (rewrite guile-avahi)))
    (parameterize ((%current-system "aarch64-linux") (%current-target-system #f))
      (and (eq? (package-source guile-avahi/namespace-aware) (package-source p))
           (every file-exists? (origin-patches (package-source p)))
           (eq? (rewrite guile-3.0) (lookup-package-input p "guile"))
           (apply (lambda* (#:key (parallel-tests? #t) (tests? #t) #:allow-other-keys)
                    (and tests? (not parallel-tests?)))
                  (package-arguments p))))))

(define runner (test-runner-current))
(test-end "native-guile-tools")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
