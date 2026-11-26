;; Exercise the actual image entry point and target OS graphs, without building
;; packages or depending on a public cache's current contents.
(use-modules (spartan packages mixed))
((@@ (spartan packages mixed) %native-outputs-available?) (const #t))
(use-modules (gnu)
             (gnu bootloader grub)
             (gnu image)
             (gnu packages base)
             (gnu packages flashing-tools)
             (gnu packages guile)
             (gnu packages virtualization)
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
             (spartan system build-policy)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "policy-images")

(define (depends-on? root target)
  (define seen (make-hash-table))
  (define (walk drv)
    (let ((name (derivation-file-name drv)))
      (cond ((string=? name target) #t)
            ((hash-ref seen name) #f)
            (else
             (hash-set! seen name #t)
             (any (lambda (input) (walk (derivation-input-derivation input)))
                  (derivation-inputs drv))))))
  (walk root))

(with-store store
  (parameterize ((%graft? #f))
    (define (lower object system)
      (run-with-store store (lower-object object system #:target #f)))
    (define (host-drv p)
      (package-derivation store p "x86_64-linux" #:graft? #f))

    (for-each
     (lambda (img system label)
       (parameterize ((%current-system system) (%current-target-system #f))
         (let* ((os (operating-system-for-image img))
                (policy (operating-system-build-policy os))
                (drv (lower (system-image img) system))
                (os-drv (lower os system))
                (profile (service-value
                          (fold-services (operating-system-services os)
                                         #:target-type profile-service-type))))
           (test-equal (string-append label ": assembly executes on the build host")
             "x86_64-linux" (derivation-system drv))
           (test-equal (string-append label ": embedded OS retains native target compilation")
             system (derivation-system os-drv))
           (test-equal (string-append label ": direct system/deploy lowering has the same policy scope")
             (derivation-file-name os-drv)
             (derivation-file-name
              (run-with-store store (operating-system-derivation os)
                              #:system system #:target #f)))
           (test-assert (string-append label ": image contains its target OS derivation")
             (depends-on? drv (derivation-file-name os-drv)))
           (test-assert (string-append label ": original host genimage and QEMU are image inputs")
             (every (lambda (p)
                      (member (derivation-file-name (host-drv p))
                              (map derivation-input-path (derivation-inputs drv))))
                    (list genimage qemu-minimal coreutils)))
           (test-assert (string-append label ": combined profile has coherent propagated libraries")
             (run-with-store store
               (check-for-collisions (packages->manifest profile) system)))
           (test-assert (string-append label ": image conversion retains the selected policy")
             (eq? policy (operating-system-build-policy (image-operating-system img)))))))
     (list rpi2-barebones-raw-image rpi3-barebones-raw-image rpi4-barebones-raw-image)
     '("armhf-linux" "aarch64-linux" "aarch64-linux")
     '("Pi 2" "Pi 3 / A53" "Pi 4 / non-A53"))

    (define plain-os
      (operating-system
        (host-name "plain-x86")
        (bootloader (bootloader-configuration (bootloader grub-bootloader)))
        (file-systems (cons (file-system
                             (device (file-system-label "Guix"))
                             (mount-point "/") (type "ext4"))
                           %base-file-systems))))
    (define plain-image (os->image plain-os #:type mbr-raw-image-type))
    (test-assert "an x86 OS has no policy unless explicitly selected"
      (not (operating-system-build-policy plain-os)))
    (test-equal "plain x86 image is exactly the upstream image derivation after importing Pi modules"
      (derivation-file-name
       (lower ((@@ (spartan system image) original-system-image) plain-image) "x86_64-linux"))
      (derivation-file-name (lower (system-image plain-image) "x86_64-linux")))
    (test-equal "explicit x86-on-x86 policy also assembles natively"
      "x86_64-linux"
      (derivation-system
       (lower (system-image
               (os->image (with-build-policy plain-os
                            (make-build-policy #:system "x86_64-linux"
                                               #:build-system "x86_64-linux"))
                          #:type mbr-raw-image-type))
              "x86_64-linux")))))

(define runner (test-runner-current))
(test-end "policy-images")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
