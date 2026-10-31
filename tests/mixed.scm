(use-modules (gnu packages base)
             (gnu packages guile)
             (gnu packages man)
             (gnu system)
             (gnu system images raspberrypi)
             (guix build-system)
             ((guix config) #:select (%system))
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix monads)
             (guix packages)
             (guix profiles)
             (guix search-paths)
             (guix store)
             (guix utils)
             (nongnu packages linux)
             (spartan packages guile)
             (spartan packages mixed)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "mixed-compilation")

(define routed
  (package-with-compilation-system hello #:system "x86_64-linux"))

(test-assert "default compilation platform is independent of the image system"
  (parameterize ((%current-system "aarch64-linux"))
    (string=? %system
              (bag-system (package->bag
                           (package-with-compilation-system hello)
                           "aarch64-linux" #f)))))

(test-assert "one adapter routes native, cross and native requests without copies"
  (and (eq? (package->bag routed "x86_64-linux" #f)
            (package->bag hello "x86_64-linux" #f #:graft? #f))
       (eq? (package->bag routed "aarch64-linux" #f)
            (package->bag hello "x86_64-linux" "aarch64-linux-gnu"
                          #:graft? #f))
       (eq? (package->bag routed "x86_64-linux" #f)
            (package->bag hello "x86_64-linux" #f #:graft? #f))))

(test-assert "equivalent explicit target and compilation triplets select native lowering"
  (let ((p (package-with-compilation-system
            hello #:system "aarch64-unknown-linux-gnu")))
    (and (eq? (package->bag p "x86_64-linux" "aarch64-linux-gnu")
              (package->bag hello "aarch64-linux" #f #:graft? #f))
         (not (bag-target (package->bag p "aarch64-linux" #f))))))

(test-assert "runner-native tools never receive a cross target"
  (not (bag-target (package->bag guile-3.0/cortex-a53 %system #f))))

(test-assert "Guile outputs, search paths and kernel properties survive adaptation"
  (and (equal? (package-outputs guile-3.0) (package-outputs guile-3.0/cortex-a53))
       (equal? (package-native-search-paths guile-3.0)
               (package-native-search-paths guile-3.0/cortex-a53))
       (equal? (package-properties linux-arm64-generic)
               (package-properties (operating-system-kernel rpi3-barebones-os)))))

(test-assert "unaffected base packages retain upstream object identity"
  (and (eq? hello (package-with-cortex-a53-guile hello))
       (eq? man-db (package-with-cortex-a53-guile man-db))
       (memq man-db (operating-system-packages rpi3-barebones-os))))

(define consumer
  (package
    (inherit hello)
    (inputs `(("guile" ,guile-3.0 "debug")))
    (propagated-inputs (list guile-3.0-latest))
    (native-inputs (list guile-3.0 hello))))
(define rewritten (package-with-cortex-a53-guile consumer))

(define replacement-dependency
  (package (inherit hello) (version "replacement")))
(define original-dependency
  (package (inherit hello) (replacement replacement-dependency)))
(define graft-consumer
  (package
    (inherit hello)
    (inputs `(("dependency" ,original-dependency "out")))))

(test-assert "runtime rewrite preserves outputs and aligns duplicate native Guile inputs"
  (and (equal? (assoc "guile" (package-inputs rewritten))
               (list "guile" guile-3.0/cortex-a53 "debug"))
       (eq? guile-3.0-latest/cortex-a53
            (lookup-package-propagated-input rewritten "guile"))
       (eq? guile-3.0/cortex-a53 (lookup-package-native-input rewritten "guile"))
       (eq? hello (lookup-package-native-input rewritten "hello"))
       (eq? rewritten (package-with-cortex-a53-guile consumer))))

(test-assert "build-only Guile does not cause unrelated packages to be rewritten"
  (let ((p (package (inherit hello) (native-inputs (list guile-3.0)))))
    (eq? p (package-with-cortex-a53-guile p))))

(test-assert "Guile runtime rewrite accepts an explicit AArch64 compilation platform"
  (let* ((selected (package-with-cortex-a53-guile guile-3.0
                                                #:system "aarch64-linux"))
         (bag (package->bag selected "aarch64-linux" #f)))
    (and (string=? "aarch64-linux" (bag-system bag))
         (not (bag-target bag)))))

(with-store store
  (define (same-derivation? a b)
    (string=? (derivation-file-name a) (derivation-file-name b)))

  (define (direct-derivation base)
    (if (string=? %system "aarch64-linux")
        (package-derivation store base "aarch64-linux" #:graft? #f)
        (package-cross-derivation store base "aarch64-linux-gnu"
                                  %system #:graft? #f)))

  (test-assert "routed Guile and kernel derivations equal the runner's direct builds"
    (every
     (lambda (pair)
       (same-derivation?
        (package-derivation store (cdr pair) "aarch64-linux" #:graft? #f)
        (direct-derivation (car pair))))
     (list (cons ((@@ (spartan packages guile) guile-with-cortex-a53-fix) guile-3.0)
                 guile-3.0/cortex-a53)
           (cons ((@@ (spartan packages guile) guile-with-cortex-a53-fix)
                  guile-3.0-latest)
                 guile-3.0-latest/cortex-a53)
           (cons linux-arm64-generic
                 (operating-system-kernel rpi3-barebones-os)))))

  (test-assert "same-platform Guile adapter has the exact native derivation"
    (let* ((base ((@@ (spartan packages guile) guile-with-cortex-a53-fix) guile-3.0))
           (p (package-with-compilation-system base #:system "aarch64-linux")))
      (same-derivation? (package-derivation store base "aarch64-linux" #:graft? #f)
                        (package-derivation store p "aarch64-linux" #:graft? #f))))

  (test-assert "native consumers reference routed Guile without an upstream duplicate"
    (let* ((p (package-with-cortex-a53-guile guile-zlib))
           (drv (package-derivation store p "aarch64-linux" #:graft? #f))
           (inputs (map derivation-input-path (derivation-inputs drv)))
           (selected (package-derivation store guile-3.0/cortex-a53 "aarch64-linux"
                                         #:graft? #f))
           (upstream (package-derivation store guile-3.0 "aarch64-linux" #:graft? #f)))
      (and (string=? "aarch64-linux" (derivation-system drv))
           (member (derivation-file-name selected) inputs)
           (not (member (derivation-file-name upstream) inputs)))))

  (test-assert "package replacements are routed in the selected build context"
    (let ((p (package-with-compilation-system original-dependency #:system "x86_64-linux")))
      (eq? (package->bag p "aarch64-linux" #f #:graft? #t)
           (package->bag replacement-dependency "x86_64-linux"
                         "aarch64-linux-gnu" #:graft? #f))))

  (test-assert "dependency graft origins and replacements retain cross architecture and outputs"
    (let* ((p (package-with-compilation-system graft-consumer #:system "x86_64-linux"))
           (original (package-cross-derivation store original-dependency
                                               "aarch64-linux-gnu"
                                               "x86_64-linux" #:graft? #f))
           (grafts (package-grafts store p "aarch64-linux"))
           (graft (find (lambda (graft)
                          (same-derivation? (graft-origin graft) original))
                        grafts)))
      (and graft
           (string=? "out" (graft-origin-output graft))
           (string=? "out" (graft-replacement-output graft))
           (same-derivation?
            (parameterize ((%graft? #f))
              (run-with-store store
                (lower-object (graft-replacement graft) "aarch64-linux")))
            (package-cross-derivation store replacement-dependency "aarch64-linux-gnu"
                                      "x86_64-linux" #:graft? #f)))))

  (test-assert "propagated profile inputs match the selected cross dependencies"
    (parameterize ((%current-system "aarch64-linux") (%current-target-system #f))
      (let* ((base ((@@ (spartan packages guile) guile-with-cortex-a53-fix) guile-3.0))
             (dependencies (package-propagated-inputs base))
             (entry (package->manifest-entry guile-3.0/cortex-a53 "debug")))
        (and (string=? "debug" (manifest-entry-output entry))
             (equal? (package-native-search-paths base)
                     (manifest-entry-search-paths entry))
             (= (length dependencies) (length (manifest-entry-dependencies entry)))
             (every
              (lambda (input entry)
                (same-derivation?
                 (direct-derivation (cadr input))
                 (package-derivation store (manifest-entry-item entry)
                                     "aarch64-linux" #:graft? #f)))
              dependencies (manifest-entry-dependencies entry)))))))

(define runner (test-runner-current))
(test-end "mixed-compilation")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
