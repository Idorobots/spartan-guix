(use-modules (gnu)
             (gnu bootloader grub)
             ((gnu packages admin) #:select (shepherd-1.0 sudo))
             ((gnu packages dns) #:select (avahi))
             ((gnu packages freedesktop) #:select (elogind))
             (gnu packages glib)
             (gnu packages gnupg)
             (gnu packages linux)
             ((gnu packages monitoring) #:select (prometheus-node-exporter))
             ((gnu packages package-management) #:select (guix))
             (gnu packages virtualization)
             (gnu packages xml)
             (gnu services avahi)
             (gnu services dbus)
             (gnu services ssh)
             (gnu system image)
             (guix build-system)
             (guix derivations)
             (guix gexp)
             (guix grafts)
             (guix packages)
             (guix store)
             (spartan system arm-workarounds)
             (spartan packages mixed)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "arm-workarounds")

(define host-extra-mixed-packages
  (list glib dbus avahi elogind prometheus-node-exporter))
(test-begin "arm-workarounds")

(define base-os
  (operating-system
   (host-name "arm-workarounds-test")
   (bootloader (bootloader-configuration (bootloader grub-bootloader)))
   (file-systems %base-file-systems)
   (services (cons* (service dbus-root-service-type)
                    (service avahi-service-type)
                    (service openssh-service-type)
                    %base-services))))

(define (dependency-path root target)
  (define seen (make-hash-table))
  (define (walk drv path)
    (let ((name (derivation-file-name drv)))
      (cond
       ((string=? name target) (reverse (cons name path)))
       ((hash-ref seen name) #f)
       (else
        (hash-set! seen name #t)
        (any (lambda (input)
               (walk (derivation-input-derivation input) (cons name path)))
             (derivation-inputs drv))))))
  (walk root '()))

(define original-arm
  (with-store store
    (package-derivation store libgpg-error "armhf-linux" #:graft? #f)))
(define original-aarch64
  (with-store store
    (package-derivation store libgpg-error "aarch64-linux" #:graft? #f)))
(define original-x86
  (with-store store
    (package-derivation store libgpg-error "x86_64-linux" #:graft? #f)))

(define original-aarch64-glib
  (with-store store
    (package-derivation store glib "aarch64-linux" #:graft? #f)))

(define original-aarch64-dbus
  (with-store store
    (package-derivation store dbus "aarch64-linux" #:graft? #f)))

(define original-aarch64-pam
  (with-store store
    (package-derivation store linux-pam "aarch64-linux" #:graft? #f)))

(with-store store
  (parameterize ((%graft? #f))
    (define (lower object system)
      (run-with-store store (lower-object object system #:target #f)))
    (define (armhf package)
      ((@@ (spartan system arm-workarounds) rewrite-armhf-packages) package))
    (define (aarch64 package)
      ((@@ (spartan system arm-workarounds) rewrite-aarch64-packages) package))
    (define original-compiler ((@@ (guix gexp) lookup-compiler) libgpg-error))

    (test-equal "importing the layer does not replace the package compiler"
      (@@ (spartan system arm-workarounds) %original-package-lower)
      original-compiler)

    (with-armhf-workarounds base-os)
    (with-aarch64-workarounds base-os)

    (test-assert "unpatched substitute availability skips the patch"
      (parameterize (((@@ (spartan packages mixed) %native-outputs-available?)
                      (const #t)))
        (eq? libgpg-error
             ((@@ (spartan system arm-workarounds) fix-armhf-package)
              libgpg-error "armhf-linux"))))

    (test-assert "missing substitute selects the patched recipe"
      (parameterize (((@@ (spartan packages mixed) %native-outputs-available?)
                      (const #f)))
        (not (eq? libgpg-error
                  ((@@ (spartan system arm-workarounds) fix-armhf-package)
                   libgpg-error "armhf-linux")))))

    (test-equal "armhf libgpg-error uses the patched derivation"
      (derivation-file-name (lower (armhf libgpg-error) "armhf-linux"))
      (derivation-file-name (lower libgpg-error "armhf-linux")))

    (test-equal "aarch64 libgpg-error retains its original derivation"
      (derivation-file-name original-aarch64)
      (derivation-file-name (lower libgpg-error "aarch64-linux")))

    (test-equal "native x86 libgpg-error retains its original derivation"
      (derivation-file-name original-x86)
      (derivation-file-name (lower libgpg-error "x86_64-linux")))

    (test-assert "host-specific packages are not in the base consumer list"
      (not (eq? 'mixed-compilation
                (build-system-name (package-build-system (rpi2-package dbus))))))

    (test-equal "elogind uses mixed compilation on armhf"
      'mixed-compilation
      (build-system-name (package-build-system (rpi2-package elogind #:extra-mixed-packages host-extra-mixed-packages))))
    (test-equal "elogind uses mixed compilation on aarch64"
      'mixed-compilation
      (build-system-name (package-build-system (rpi4-package elogind #:extra-mixed-packages host-extra-mixed-packages))))

    (test-equal "glib uses mixed compilation on armhf"
      'mixed-compilation
      (build-system-name (package-build-system (rpi2-package glib #:extra-mixed-packages host-extra-mixed-packages))))
    (test-equal "glib uses mixed compilation on aarch64"
      'mixed-compilation
      (build-system-name (package-build-system (rpi4-package glib #:extra-mixed-packages host-extra-mixed-packages))))

    (test-equal "avahi uses mixed compilation on armhf"
      'mixed-compilation
      (build-system-name (package-build-system (rpi2-package avahi #:extra-mixed-packages host-extra-mixed-packages))))
    (test-equal "avahi uses mixed compilation on aarch64"
      'mixed-compilation
      (build-system-name (package-build-system (rpi4-package avahi #:extra-mixed-packages host-extra-mixed-packages))))
    (test-equal "dbus uses mixed compilation on armhf"
      'mixed-compilation
      (build-system-name (package-build-system (rpi2-package dbus #:extra-mixed-packages host-extra-mixed-packages))))
    (test-equal "dbus uses mixed compilation on aarch64"
      'mixed-compilation
      (build-system-name (package-build-system (rpi4-package dbus #:extra-mixed-packages host-extra-mixed-packages))))

    (test-equal "prometheus-node-exporter uses mixed compilation on armhf"
      'mixed-compilation
      (build-system-name
       (package-build-system
        (rpi2-package prometheus-node-exporter
                      #:extra-mixed-packages host-extra-mixed-packages))))
    (test-equal "prometheus-node-exporter uses mixed compilation on aarch64"
      'mixed-compilation
      (build-system-name
       (package-build-system
        (rpi4-package prometheus-node-exporter
                      #:extra-mixed-packages host-extra-mixed-packages))))

    (test-assert "libxslt retains EXSLT crypto with patched armhf dependencies"
      (let ((xslt (armhf libxslt)))
        (and (lookup-package-input xslt "libgcrypt")
             (not (dependency-path (lower xslt "armhf-linux")
                                   (derivation-file-name original-arm))))))

    (for-each
     (lambda (system rewrite)
       (test-equal (string-append system " sudo stays inside the build for tmpfiles")
         (derivation-file-name
          (package-derivation store (rewrite sudo) system #:graft? #f))
         (derivation-file-name (lower sudo system)))
       (when (string=? system "armhf-linux")
         (test-equal "armhf PAM uses Guix's standard library layout"
           (derivation-file-name
            (package-derivation store (rewrite linux-pam) system #:graft? #f))
           (derivation-file-name (lower linux-pam system)))
         (test-equal "armhf D-Bus uses Guix's standard library layout"
           (derivation-file-name
            (package-derivation store (rewrite dbus) system #:graft? #f))
           (derivation-file-name (lower dbus system)))
         (test-equal "armhf GLib uses Guix's standard library layout"
           (derivation-file-name
            (package-derivation store (rewrite glib) system #:graft? #f))
           (derivation-file-name (lower glib system)))))
     '("armhf-linux" "aarch64-linux")
     (list armhf aarch64))

    (test-assert "PAM's rewritten recipe forces the standard library directory"
      (string-contains (object->string (package-arguments (armhf linux-pam)))
                       "-Dlibdir=lib"))
    (test-assert "D-Bus's rewritten recipe forces the standard library directory"
      (string-contains (object->string (package-arguments (armhf dbus)))
                       "-Dlibdir=lib"))
    (test-assert "GLib's armhf recipe forces the standard library directory"
      (string-contains (object->string (package-arguments (armhf glib)))
                       "-Dlibdir=lib"))
    (test-equal "aarch64 PAM retains its original derivation"
      (derivation-file-name original-aarch64-pam)
      (derivation-file-name (lower linux-pam "aarch64-linux")))
    (test-equal "aarch64 D-Bus retains its original derivation"
      (derivation-file-name original-aarch64-dbus)
      (derivation-file-name (lower dbus "aarch64-linux")))
    (test-equal "aarch64 GLib retains its original derivation"
      (derivation-file-name original-aarch64-glib)
      (derivation-file-name (lower glib "aarch64-linux")))
    (test-assert "sudo's rewritten recipe uses the sandbox tmpfiles directory"
      (string-contains (object->string (package-arguments (armhf sudo)))
                       "--enable-tmpfiles.d=/tmp/dummy"))))

(define runner (test-runner-current))
(test-end "arm-workarounds")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
