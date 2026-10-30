(use-modules (gnu)
             (gnu image)
             (gnu packages linux)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix build-system)
             (guix derivations)
             (guix packages)
             (guix store)
             (guix utils)
             (spartan packages linux)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "alsa-cross")

(test-assert "ALSA bootstrap tools run on the build machine"
  (let ((bag (package->bag alsa-lib/cross-fixed
                           "x86_64-linux" "aarch64-linux-gnu")))
    (every (lambda (name)
             (and (assoc-ref (bag-build-inputs bag) name)
                  (not (assoc-ref (bag-host-inputs bag) name))))
           '("autoconf" "automake" "libtool"))))

(test-assert "native ALSA library and utilities retain upstream derivations"
  (with-store store
    (every
     (lambda (pair)
       (every (lambda (system)
                (string=?
                 (derivation-file-name
                  (package-derivation store (car pair) system #:graft? #f))
                 (derivation-file-name
                  (package-derivation store (cdr pair) system #:graft? #f))))
              '("x86_64-linux" "aarch64-linux")))
     (list (cons alsa-lib alsa-lib/cross-fixed)
           (cons alsa-utils alsa-utils/cross-fixed)))))

(test-assert "cross-built udev rules have target cat and corrected ALSA"
  (let ((bag (package->bag alsa-utils/cross-fixed
                           "x86_64-linux" "aarch64-linux-gnu")))
    (and (assoc-ref (bag-host-inputs bag) "coreutils-minimal")
         (equal? (assoc-ref (bag-host-inputs bag) "alsa-lib")
                 (list alsa-lib/cross-fixed)))))

(test-assert "udev retains ALSA rules with the corrected library before and after conversion"
  (every
   (lambda (os)
     (let* ((services (operating-system-services os))
            (config (service-value (fold-services services #:target-type udev-service-type)))
            (alsa (find (lambda (item)
                          (and (package? item)
                               (string=? "alsa-utils" (package-name item))))
                        (udev-configuration-rules config))))
        (and alsa
             (parameterize ((%current-target-system "aarch64-linux-gnu"))
               (eq? alsa-lib/cross-fixed (lookup-package-input alsa "alsa-lib"))))))
   (list rpi3-barebones-os
         (operating-system-for-image
          (os->image rpi3-barebones-os #:type rpi-image-type)))))

(define runner (test-runner-current))
(test-end "alsa-cross")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
