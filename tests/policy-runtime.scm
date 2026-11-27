(use-modules (spartan packages mixed))
((@@ (spartan packages mixed) %native-outputs-available?) (const #f))
(use-modules (gnu)
             (gnu image)
             ((gnu packages admin) #:select (sudo))
             (gnu packages glib)
             (gnu packages gnupg)
             (gnu packages guile)
             (gnu packages linux)
             (gnu packages python-build)
             (gnu packages python-xyz)
             (gnu packages xml)
             (gnu services shepherd)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix build-system)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix packages)
             (guix profiles)
             (guix store)
             (guix utils)
             (spartan packages build-fixes)
             (spartan system build-policy)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "policy-runtime")

(define (a53-flags? p system)
  (parameterize ((%current-system system) (%current-target-system #f))
    (string-contains (object->string (package-arguments p)) "--fix-cortex-a53-843419")))

(for-each
 (lambda (os system cortex?)
   (let* ((policy (operating-system-build-policy os))
          (kernel (operating-system-kernel os))
          (firmware (car (operating-system-firmware os))))
     (test-assert (string-append system (if cortex? " A53" "") ": kernel and firmware are mixed")
       (every (lambda (p)
                (let ((bag (package->bag p system #f #:graft? #f)))
                  (and (string=? "x86_64-linux" (bag-system bag))
                       (string=? (if (string=? system "armhf-linux")
                                     "arm-linux-gnueabihf" "aarch64-linux-gnu")
                                 (bag-target bag)))))
              (list kernel firmware)))
     (test-equal (string-append system ": firmware is the uncompressed recipe")
       "linux-firmware-uncompressed" (package-name firmware))
     (test-equal (string-append system (if cortex? " A53" "") ": board Guile fix is explicit")
       cortex?
       (and (a53-flags? (build-policy-package policy guile-3.0) system) #t))
     (test-assert (string-append system ": reapplying the policy does not stack adapters")
       (let ((again (with-build-policy os policy)))
         (and (eq? kernel (operating-system-kernel again))
              (equal? (operating-system-packages os) (operating-system-packages again)))))
     (with-store store
       (parameterize ((%current-system system) (%current-target-system #f) (%graft? #f))
         (test-assert (string-append system (if cortex? " A53" "") ": fallback profiles are coherent")
           (every
            (lambda (os)
              (run-with-store store
                (check-for-collisions
                 (packages->manifest
                  (service-value (fold-services (operating-system-services os)
                                                #:target-type profile-service-type)))
                 system)))
            (list os (operating-system-for-image
                      (os->image os #:type (if (string=? system "armhf-linux")
                                              rpi2-image-type rpi-image-type))))))))))
 (list rpi2-barebones-os rpi3-barebones-os rpi4-barebones-os)
 '("armhf-linux" "aarch64-linux" "aarch64-linux") '(#f #t #f))

(test-assert "replacing an inherited A53 policy removes the board-specific fix"
  (let* ((os (with-build-policy rpi3-barebones-os %rpi4-build-policy))
         (guile (find (lambda (p) (string=? (package-name p) "guile"))
                      (operating-system-packages os))))
    (not (a53-flags? guile "aarch64-linux"))))

(test-assert "ARM-only fixes do not alter AArch64 or x86 recipes"
  (every (lambda (p)
           (and (not (eq? p (package-build-fix p "armhf-linux")))
                (eq? p (package-build-fix p "aarch64-linux"))
                (eq? p (package-build-fix p "x86_64-linux"))))
         (list libgpg-error linux-pam dbus glib python-trio)))

(test-assert "common sandbox and test fallbacks retain their fixes"
  (and (string-contains (object->string
                        (package-arguments (package-build-fix sudo "armhf-linux")))
                       "--enable-tmpfiles.d=/tmp/dummy")
       (string-contains
        (object->string
         (package-arguments (package-build-fix gobject-introspection "x86_64-linux")))
        "-Dlibdir=lib")))

(test-assert "cross-built full GLib enables target introspection for native consumers"
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "arm-linux-gnueabihf"))
    (let* ((fixed (package-build-fix glib "armhf-linux"))
           (bag (package->bag fixed "x86_64-linux" "arm-linux-gnueabihf" #:graft? #f))
           (arguments (object->string (bag-arguments bag))))
      (and (lookup-package-input fixed "gobject-introspection")
           (lookup-package-native-input fixed "gobject-introspection")
           (string=? "x86_64-linux" (bag-system bag))
           (string=? "arm-linux-gnueabihf" (bag-target bag))
           (string-contains arguments "-Dintrospection=enabled")
           (string-contains arguments "needs_exe_wrapper = false")
           (string-contains arguments "-Dlibdir=lib")))))

(test-assert "cross-built bootstrap GLib does not acquire an introspection cycle"
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "arm-linux-gnueabihf"))
    (let ((fixed (package-build-fix (@@ (gnu packages glib) glib-minimal)
                                    "armhf-linux")))
      (and (not (lookup-package-input fixed "gobject-introspection"))
           (not (string-contains (object->string (package-arguments fixed))
                                 "-Dintrospection=enabled"))))))

(for-each
 (lambda (target)
   (test-assert (string-append target ": setuptools fallback has build-machine Python")
     (call-with-values
         (lambda () (make-native-first-package-mapper package-build-fix))
       (lambda (rewrite owns?)
         (let* ((bag (package->bag (rewrite python-setuptools-bootstrap)
                                  "x86_64-linux" target #:graft? #f))
                (python (assoc-ref (bag-build-inputs bag) "python")))
           ;; Exercise fallback dispatch and GNU input classification, not just
           ;; the fixed package's fields: only build inputs go on cross PATH.
           (and (string=? "x86_64-linux" (bag-system bag))
                (string=? target (bag-target bag))
                python
                (string=? "python-wrapper" (package-name (car python)))
                (assoc "python-wrapper" (bag-host-inputs bag))))))))
 '("arm-linux-gnueabihf" "aarch64-linux-gnu"))

(test-assert "native setuptools bootstrap keeps the upstream recipe"
  (every (lambda (system)
           (parameterize ((%current-system system) (%current-target-system #f))
             (eq? python-setuptools-bootstrap
                  (package-build-fix python-setuptools-bootstrap system))))
         '("armhf-linux" "aarch64-linux" "x86_64-linux")))

(for-each
 (lambda (target)
   (test-assert (string-append target ": introspection variants have native setuptools")
     (parameterize ((%current-system "x86_64-linux")
                    (%current-target-system target))
       (every
        (lambda (base)
          (let* ((setuptools (lookup-package-propagated-input
                             base "python-setuptools-bootstrap"))
                 (fixed (package-build-fix base (gnu-triplet->nix-system target)))
                 (bag (package->bag fixed "x86_64-linux" target #:graft? #f)))
            (and (eq? setuptools
                      (car (assoc-ref (bag-build-inputs bag)
                                      "python-setuptools-bootstrap")))
                 (eq? setuptools
                      (lookup-package-propagated-input
                       fixed "python-setuptools-bootstrap"))
                 (string-contains (object->string (bag-arguments bag))
                                  "-Dlibdir=lib")
                 (string-contains (object->string (bag-arguments bag))
                                  "-Dbuild_introspection_data=false"))))
        (list (@@ (gnu packages glib) gobject-introspection-minimal)
              gobject-introspection)))))
 '("arm-linux-gnueabihf" "aarch64-linux-gnu"))

(test-assert "native introspection variants retain their original build inputs"
  (parameterize ((%current-system "x86_64-linux") (%current-target-system #f))
    (every (lambda (base)
             (equal? (package-native-inputs base)
                     (package-native-inputs
                      (package-build-fix base "x86_64-linux"))))
           (list (@@ (gnu packages glib) gobject-introspection-minimal)
                 gobject-introspection))))

(test-assert "EXSLT crypto remains enabled under the ARM policy"
  (lookup-package-input (build-policy-package %rpi2-build-policy libxslt) "libgcrypt"))

(define runner (test-runner-current))
(test-end "policy-runtime")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
