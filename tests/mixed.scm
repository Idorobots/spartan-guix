(use-modules ((gnu packages admin) #:select (shepherd-0.10 shepherd-1.0))
             (gnu packages base)
             (gnu packages guile)
             (gnu packages man)
             ((gnu packages package-management) #:select (guix))
             ((gnu packages ssh) #:select (guile-ssh))
             (gnu image)
             (gnu services)
             (gnu system)
             (gnu system image)
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
             (spartan packages guile-config)
             (spartan packages guile-snarf)
             (spartan packages mixed)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "mixed-compilation")

(define guile-3.0/rpi3 (rpi3-package guile-3.0))
(define guile-3.0-latest/rpi3 (rpi3-package guile-3.0-latest))
(define sdk-fixes (compose guile-with-native-snarf guile-with-native-config))
(define* (sdk-package p #:key (system %system))
  ((make-guile-runtime-rewriter #:guile-transform sdk-fixes #:system system) p))

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
  (not (bag-target (package->bag guile-3.0/rpi3 %system #f))))

(test-assert "Guile outputs, search paths and kernel properties survive adaptation"
  (and (equal? (package-outputs guile-3.0) (package-outputs guile-3.0/rpi3))
       (equal? (package-native-search-paths guile-3.0)
                (package-native-search-paths guile-3.0/rpi3))
       (equal? (package-properties linux-arm64-generic)
               (package-properties (operating-system-kernel rpi3-barebones-os)))))

(test-assert "unaffected base packages retain upstream object identity"
  (and (eq? hello (rpi3-package hello))
       (eq? man-db (rpi3-package man-db))
       (memq man-db (operating-system-packages rpi3-barebones-os))))

(define consumer
  (package
    (inherit hello)
    (inputs `(("guile" ,guile-3.0 "debug")))
    (propagated-inputs (list guile-3.0-latest))
    (native-inputs (list guile-3.0 hello))))
(define rewritten (rpi3-package consumer))

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
               (list "guile" guile-3.0/rpi3 "debug"))
       (eq? guile-3.0-latest/rpi3
            (lookup-package-propagated-input rewritten "guile"))
       (eq? guile-3.0/rpi3 (lookup-package-native-input rewritten "guile"))
       (eq? hello (lookup-package-native-input rewritten "hello"))
       (eq? rewritten (rpi3-package consumer))))

(test-assert "build-only Guile does not cause unrelated packages to be rewritten"
  (let ((p (package (inherit hello) (native-inputs (list guile-3.0)))))
    (eq? p (rpi3-package p))))

(test-assert "Guile runtime rewrite accepts an explicit AArch64 compilation platform"
  (let* ((selected (rpi3-package guile-3.0
                                                #:system "aarch64-linux"))
         (bag (package->bag selected "aarch64-linux" #f)))
    (and (string=? "aarch64-linux" (bag-system bag))
         (not (bag-target bag)))))

(define selective-consumers (list guix shepherd-0.10 shepherd-1.0 guile-ssh guile-readline))

(test-assert "selected consumers cross-build on x86 and build natively on AArch64"
  (every
   (lambda (base)
     (let* ((cross (rpi3-package base #:system "x86_64-linux"))
            (native (rpi3-package base #:system "aarch64-linux"))
            (cross-bag (package->bag cross "aarch64-linux" #f))
            (native-bag (package->bag native "aarch64-linux" #f)))
       (and (string=? "x86_64-linux" (bag-system cross-bag))
            (string=? "aarch64-linux-gnu" (bag-target cross-bag))
            (string=? "aarch64-linux" (bag-system native-bag))
            (not (bag-target native-bag))
            (eq? (package-source base) (package-source cross))
            (equal? (package-outputs base) (package-outputs cross)))))
   selective-consumers))

(test-assert "cross consumers preserve upstream build tools and patched runtime Guile"
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "aarch64-linux-gnu"))
    (every
     (lambda (base)
       (let ((p (rpi3-package base #:system "x86_64-linux")))
         (and (equal? (package-native-inputs base) (package-native-inputs p))
              (eq? (rpi3-package (lookup-package-input base "guile")
                                                #:system "x86_64-linux")
                   (lookup-package-input p "guile")))))
     selective-consumers)))

(test-assert "Guix propagates cross-built SSH separately from its native build-time SSH"
  (let* ((p (rpi3-package guix #:system "x86_64-linux"))
         (runtime
          (parameterize ((%current-system "aarch64-linux") (%current-target-system #f))
            (lookup-package-propagated-input p "guile-ssh")))
         (build
          (parameterize ((%current-system "x86_64-linux")
                         (%current-target-system "aarch64-linux-gnu"))
            (lookup-package-native-input p "guile-ssh")))
         (runtime-bag (package->bag runtime "aarch64-linux" #f))
         (build-bag (package->bag build "x86_64-linux" #f)))
    (and (eq? guile-ssh build)
         (string=? "x86_64-linux" (bag-system runtime-bag))
         (string=? "aarch64-linux-gnu" (bag-target runtime-bag))
         (string=? "x86_64-linux" (bag-system build-bag))
         (not (bag-target build-bag)))))

(test-assert "Shepherd propagates target Fibers separately from native build-time Fibers"
  (parameterize ((%current-system "aarch64-linux") (%current-target-system #f))
    (let* ((p (rpi3-package shepherd-1.0 #:system "x86_64-linux"))
           (runtime (lookup-package-propagated-input p "guile-fibers"))
           (build (lookup-package-native-input p "guile-fibers"))
           (runtime-bag (package->bag runtime "aarch64-linux" #f))
           (build-bag (package->bag build "x86_64-linux" #f)))
      (and (string=? "x86_64-linux" (bag-system runtime-bag))
           (string=? "aarch64-linux-gnu" (bag-target runtime-bag))
           (string=? "x86_64-linux" (bag-system build-bag))
           (not (bag-target build-bag))))))

(with-store store
  (define (same-derivation? a b)
    (string=? (derivation-file-name a) (derivation-file-name b)))

  (define (direct-derivation base)
    (if (string=? %system "aarch64-linux")
        (package-derivation store base "aarch64-linux" #:graft? #f)
        (package-cross-derivation store base "aarch64-linux-gnu"
                                   %system #:graft? #f)))

  (define (collision-free? packages)
    ;; Exercise Guix's real manifest collision check without realizing graft
    ;; prerequisites.  This only lowers derivations; it does not build a profile.
    (parameterize ((%current-system "aarch64-linux")
                   (%current-target-system #f)
                   (%graft? #f))
      (run-with-store store
        (check-for-collisions (packages->manifest packages) "aarch64-linux"))))

  (test-assert "routed Readline propagates its selected Guile's complete library list"
    (parameterize ((%current-system "aarch64-linux") (%current-target-system #f))
      (every
       (lambda (system)
         (let* ((p (rpi3-package guile-readline #:system system))
                (guile (lookup-package-input p "guile"))
                (bag (package->bag p "aarch64-linux" #f)))
           (and (equal? (package-propagated-inputs guile)
                        (package-propagated-inputs p))
                (string=? system (bag-system bag))
                (equal? (and (not (string=? system "aarch64-linux"))
                             "aarch64-linux-gnu")
                        (bag-target bag)))))
       '("x86_64-linux" "aarch64-linux"))))

  (for-each
   (lambda (system)
     (test-assert (string-append "Readline and interactive Guile share a profile, compiled on " system)
       (collision-free?
        (map (lambda (p) (rpi3-package p #:system system))
             (list guile-readline guile-3.0-latest)))))
   '("x86_64-linux" "aarch64-linux"))

  (test-assert "SDK-only profiles share libraries and consumers retain cross/native routing"
    (every
     (lambda (system)
       (let ((target (and (not (string=? system "aarch64-linux"))
                          "aarch64-linux-gnu")))
         (and (collision-free?
               (map (lambda (p) (sdk-package p #:system system))
                    (list guile-readline guile-3.0-latest)))
              (every
               (lambda (base)
                 (let ((bag (package->bag (sdk-package base #:system system)
                                         "aarch64-linux" #f)))
                   (and (string=? system (bag-system bag))
                        (equal? target (bag-target bag)))))
               selective-consumers))))
     '("x86_64-linux" "aarch64-linux")))

  (test-assert "combined base system profiles have no collisions before or after image conversion"
    (every
     (lambda (os)
       (collision-free?
        (service-value
         (fold-services (operating-system-services os) #:target-type profile-service-type))))
     (list rpi3-barebones-os
           (operating-system-for-image (os->image rpi3-barebones-os #:type rpi-image-type)))))

  (test-assert "routed Guile and kernel derivations equal the runner's direct builds"
    (every
     (lambda (pair)
       (same-derivation?
        (package-derivation store (cdr pair) "aarch64-linux" #:graft? #f)
        (direct-derivation (car pair))))
     (list (cons (rpi3-guile-fixes guile-3.0) guile-3.0/rpi3)
           (cons (rpi3-guile-fixes guile-3.0-latest) guile-3.0-latest/rpi3)
           (cons linux-arm64-generic
                 (operating-system-kernel rpi3-barebones-os)))))

  (test-assert "same-platform Guile adapter has the exact native derivation"
    (let* ((base (rpi3-guile-fixes guile-3.0))
           (p (package-with-compilation-system base #:system "aarch64-linux")))
      (same-derivation? (package-derivation store base "aarch64-linux" #:graft? #f)
                        (package-derivation store p "aarch64-linux" #:graft? #f))))

  (test-assert "native consumers reference routed Guile without an upstream duplicate"
    (let* ((p (rpi3-package guile-zlib))
           (drv (package-derivation store p "aarch64-linux" #:graft? #f))
           (inputs (map derivation-input-path (derivation-inputs drv)))
           (selected (package-derivation store guile-3.0/rpi3 "aarch64-linux"
                                         #:graft? #f))
           (upstream (package-derivation store guile-3.0 "aarch64-linux" #:graft? #f)))
      (and (string=? "aarch64-linux" (derivation-system drv))
           (member (derivation-file-name selected) inputs)
           (not (member (derivation-file-name upstream) inputs)))))

  (test-assert "selective consumers lower to x86 builds with patched AArch64 Guile"
    (every
     (lambda (base)
       (let* ((base-guile (lookup-package-input base "guile"))
              (selected (package-derivation
                         store (rpi3-package base-guile
                                                             #:system "x86_64-linux")
                         "aarch64-linux" #:graft? #f))
              (build-guile (package-derivation store base-guile "x86_64-linux"
                                               #:graft? #f))
              (upstream (package-derivation store base-guile "aarch64-linux"
                                            #:graft? #f))
              (p (rpi3-package base #:system "x86_64-linux"))
              (drv (package-derivation store p "aarch64-linux" #:graft? #f))
              (inputs (map derivation-input-path (derivation-inputs drv))))
         (and (string=? "x86_64-linux" (derivation-system drv))
              (member (derivation-file-name selected) inputs)
              (member (derivation-file-name build-guile) inputs)
              (not (member (derivation-file-name upstream) inputs)))))
     selective-consumers))

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
      (let* ((base (rpi3-guile-fixes guile-3.0))
             (dependencies (package-propagated-inputs base))
             (entry (package->manifest-entry guile-3.0/rpi3 "debug")))
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
