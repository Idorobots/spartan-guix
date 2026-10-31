(use-modules (gnu)
             (gnu image)
             (gnu packages groff)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (guix utils)
             (spartan packages groff)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "groff-cross")

(test-assert "native full and minimal Groff retain upstream derivations"
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
     (list (cons groff groff/cross-fixed)
           (cons groff-minimal groff-minimal/cross-fixed)))))

(test-assert "man-db selects upstream Groff before and after image conversion"
  (every
   (lambda (os)
     (let ((man (find (lambda (p)
                        (and (package? p) (string=? (package-name p) "man-db")))
                      (operating-system-packages os))))
        (and man (eq? groff-minimal
                      (lookup-package-input man "groff-minimal")))))
   (list rpi3-barebones-os
         (operating-system-for-image
          (os->image rpi3-barebones-os #:type rpi-image-type)))))

(define runner (test-runner-current))
(test-end "groff-cross")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
