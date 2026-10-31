(use-modules (gnu packages base)
             (gnu packages guile)
             ((gnu packages guile-xyz) #:select (guile-avahi))
             ((guix build gnu-build-system) #:prefix build:)
             (guix build-system)
             (guix build utils)
             (guix gexp)
             (guix packages)
             (guix utils)
             (spartan packages guile)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "native-guile-tools")

(define consumer
  (package
    (inherit hello)
    (inputs (list guile-3.0))
    (arguments
     (list #:phases
           #~(modify-phases %standard-phases
               (delete 'configure)
               (add-before 'build 'consumer-phase (lambda _ #t)))))))
(define selected (package-with-cortex-a53-guile consumer))
(define %standard-phases build:%standard-phases)

(define (phases system target)
  (parameterize ((%current-system system) (%current-target-system target))
    (let ((phases (apply (lambda* (#:key phases #:allow-other-keys) phases)
                         (package-arguments selected))))
      (eval (gexp->approximate-sexp phases) (current-module)))))

(define prepare
  (assq-ref (phases "aarch64-linux" #f) 'set-native-guile-preprocessor))

(test-assert "native preprocessor setup survives consumers deleting configure"
  (and prepare
       (assq-ref (phases "aarch64-linux" #f) 'consumer-phase)
       (not (assq-ref (phases "aarch64-linux" #f) 'configure))
       (not (assq-ref (phases "x86_64-linux" #f) 'set-native-guile-preprocessor))
       (not (assq-ref (phases "x86_64-linux" "aarch64-linux-gnu")
                      'set-native-guile-preprocessor))))

(test-equal "snarf defaults to the native consumer compiler" "gcc -E"
  (with-environment-variables '(("CPP" #f) ("CC" #f))
    (prepare) (getenv "CPP")))

(test-equal "consumer compiler overrides are honored" "clang --target=aarch64-linux-gnu -E"
  (with-environment-variables
      '(("CPP" #f) ("CC" "clang --target=aarch64-linux-gnu"))
    (prepare) (getenv "CPP")))

(test-equal "an explicit preprocessor is retained" "custom-cpp -DTEST"
  (with-environment-variables '(("CPP" "custom-cpp -DTEST"))
    (prepare) (getenv "CPP")))

(test-equal "empty CPP uses the native compiler default" "gcc -E"
  (with-environment-variables '(("CPP" "") ("CC" #f))
    (prepare) (getenv "CPP")))

(test-assert "cross-built Guile's SDK references native destination pkg-config"
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "aarch64-linux-gnu"))
    (every
     (lambda (guile)
       (let* ((phases (apply (lambda* (#:key phases #:allow-other-keys) phases)
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
     (list guile-3.0/cortex-a53 guile-3.0-latest/cortex-a53))))

(test-assert "selected Guile-Avahi preserves all tests and its patched interpreter"
  (parameterize ((%current-system "aarch64-linux") (%current-target-system #f))
    (let* ((p (package-with-cortex-a53-guile guile-avahi))
           (patches (origin-patches (package-source p))))
      (and (pair? patches)
           (every file-exists? patches)
           (eq? guile-3.0/cortex-a53 (lookup-package-input p "guile"))
           (apply (lambda* (#:key (parallel-tests? #t) (tests? #t)
                           #:allow-other-keys)
                    (and tests? (not parallel-tests?)))
                  (package-arguments p))))))

(define runner (test-runner-current))
(test-end "native-guile-tools")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
