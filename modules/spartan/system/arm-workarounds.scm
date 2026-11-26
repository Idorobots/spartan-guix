(define-module (spartan system arm-workarounds)
  #:use-module (srfi srfi-197)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module ((gnu packages admin) #:select (shepherd-0.10 shepherd-1.0 sudo))
  #:use-module ((gnu packages gnupg) #:select (libgpg-error))
  #:use-module ((gnu packages guile) #:select (guile-readline))
  #:use-module ((gnu packages package-management) #:select (guix))
  #:use-module ((guix config) #:select (%system))
  #:use-module ((gnu packages ssh) #:select (guile-ssh))
  #:use-module (gnu services avahi)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu services monitoring)
  #:use-module (gnu services ssh)
  #:use-module (guix build-system)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (guix utils)
  #:use-module ((gnu packages flashing-tools) #:select (genimage))
  #:use-module ((gnu packages virtualization) #:select (qemu-minimal))
  #:use-module (spartan packages cortex-a53)
  #:use-module (spartan packages guile)
  #:use-module (spartan packages guile-config)
  #:use-module (spartan packages guile-snarf)
  #:use-module (spartan packages mixed)
  #:use-module (spartan services nut)
  #:use-module (spartan services spartan-sensor-mesh)
  #:export (with-armhf-workarounds
            with-aarch64-workarounds
            rpi2-package
            rpi3-package
            rpi4-package
            rpi3-guile-fixes
            armhf-package-rewriter
            aarch64-package-rewriter
            rewrite-armhf-packages
            rewrite-aarch64-packages))

;; Temporary compatibility layer for the pinned Guix revision 2bc642182.
;; Keep architecture-independent package fixes here so the same policy reaches
;; both ARM targets.  The libgpg-error and Trio fixes are 32-bit ARM-specific;
;; aarch64 has native shell and socket behaviour and does not need them.

(define %sdk-guile-fixes
  (compose guile-with-native-snarf guile-with-native-config))

(define %cortex-guile-fixes
  (compose guile-with-cortex-a53-fix %sdk-guile-fixes))

(define rpi3-guile-fixes %cortex-guile-fixes)

(define %base-mixed-packages
  (list guix shepherd-0.10 shepherd-1.0 guile-ssh guile-readline sudo))

(define* (make-aarch64-sdk-rewriter #:key (cortex-a53? #f) (system %system)
                                     (extra-mixed-packages '()))
  (make-mixed-compilation-rewriter
   #:runtime-system "aarch64-linux"
   #:system system
   #:guile-transform (if cortex-a53? %cortex-guile-fixes %sdk-guile-fixes)
   #:consumers (append %base-mixed-packages extra-mixed-packages)))

(define* (make-armhf-sdk-rewriter #:key (system %system) (extra-mixed-packages '()))
  (make-mixed-compilation-rewriter
   #:runtime-system "armhf-linux"
   #:system system
   #:guile-transform %sdk-guile-fixes
   #:consumers (append %base-mixed-packages extra-mixed-packages)))

(define* (rpi2-package package #:key (system %system) (extra-mixed-packages '()))
  "Apply the Pi 2's SDK fixes and ARM hard-float mixed compilation policy."
  ((make-armhf-sdk-rewriter #:system system
                            #:extra-mixed-packages extra-mixed-packages)
   package))

(define* (rpi3-package package #:key (system %system) (extra-mixed-packages '()))
  "Apply the Pi 3's Cortex-A53 and SDK fixes with mixed compilation."
  ((make-aarch64-sdk-rewriter #:cortex-a53? #t #:system system
                             #:extra-mixed-packages extra-mixed-packages)
   package))

(define* (rpi4-package package #:key (system %system) (extra-mixed-packages '()))
  ;; The Pi 4's Cortex-A72 does not need the Pi 3's Cortex-A53 workaround.
  ((make-aarch64-sdk-rewriter #:system system
                              #:extra-mixed-packages extra-mixed-packages)
   package))

(define (native-substitute-available? package system)
  "Whether PACKAGE's unpatched native outputs are already available for SYSTEM."
  (and (string? system)
       (native-package-outputs-available? package system)))

(define (fix-or-substitute base system fixed)
  (if (native-substitute-available? base system)
      base
      fixed))

(define (fix-common-package base system)
  (cond
   ;; The Guile-Avahi tests create clients against an external daemon and
   ;; collide with names already published on the build host.
   ((and (string=? (package-name base) "guile-avahi")
         (string=? (package-version base) "0.4.1"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:tests? _ #t) #f))))))
   ;; HarfBuzz 11.4.4 has the same Meson lib64 default.
   ((and (string=? (package-name base) "harfbuzz")
         (string=? (package-version base) "11.4.4"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:configure-flags flags #~'())
           #~(cons "-Dlibdir=lib" #$flags)))))))
   ;; Cairo 1.18.4 also selects Meson's lib64 default in this revision.
   ((and (string=? (package-name base) "cairo")
         (string=? (package-version base) "1.18.4"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:configure-flags flags #~'())
           #~(cons "-Dlibdir=lib" #$flags)))))))
   ;; gobject-introspection 1.86.0 has the same Meson libdir issue as GLib.
   ((and (string=? (package-name base) "gobject-introspection")
         (string=? (package-version base) "1.86.0"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (append (package-arguments base)
                (list #:configure-flags #~(list "-Dlibdir=lib")))))))
   ;; Sudo 1.9.17p1 defaults its systemd tmpfiles directory to the host's
   ;; /usr/lib/tmpfiles.d; installing there fails in the build sandbox.
   ((and (string=? (package-name base) "sudo")
         (string=? (package-version base) "1.9.17p1"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:configure-flags flags #~'())
           #~(cons "--enable-tmpfiles.d=/tmp/dummy" #$flags)))))))
   ;; Guix also uses a native build-time Guile-SSH, whose tests remain enabled
   ;; even when the runtime package is cross-built.  Those tests are not
   ;; parallel-safe; retain serial execution for that native build path.
   ((string=? (package-name base) "guile-ssh")
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:parallel-tests? _ #t) #f))))))
   (else base)))

(define (fix-armhf-package base system)
  (cond
   ;; Linux-PAM 1.7.2 can select Meson's host-dependent lib64 default while
   ;; Guix's Meson builder adds $output/lib to RUNPATH.
   ((and (string=? (package-name base) "linux-pam")
         (string=? (package-version base) "1.7.2"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:configure-flags flags #~'())
           #~(cons "-Dlibdir=lib" #$flags)))))))
   ;; The rebuilt D-Bus recipe selects Meson's lib64 default while Guix's
   ;; RUNPATH validation only expects the standard lib directory.
   ((and (string=? (package-name base) "dbus")
         (string=? (package-version base) "1.16.2"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:configure-flags flags #~'())
           #~(cons "-Dlibdir=lib" #$flags)))))))
   ;; GLib 2.86.0 selects Meson's lib64 default when the build machine and
   ;; target differ, but its pkg-config phase and Guix RUNPATH validation
   ;; expect the standard lib directory.
   ((and (string=? (package-name base) "glib")
         (string=? (package-version base) "2.86.0"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:configure-flags flags #~'())
           #~(cons "-Dlibdir=lib" #$flags)))))))
   ;; ELogind's raw clone and thread-count tests exercise clone(2) details that
   ;; 32-bit ARM user emulation does not implement faithfully.
   ((and (string=? (package-name base) "elogind")
         (string=? (package-version base) "257.14"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (arguments
        (substitute-keyword-arguments (package-arguments base)
          ((#:phases phases #~%standard-phases)
           #~(modify-phases #$phases
               (add-after 'unpack 'skip-qemu-incompatible-tests
                 (lambda _
                   (substitute* '("src/test/test-process-util.c"
                                  "src/test/test-raw-clone.c")
                     (("DEFINE_TEST_MAIN_WITH_INTRO\\(LOG_INFO, intro\\);")
                      "int main(void) { return 77; }")
                     (("DEFINE_TEST_MAIN\\(LOG_INFO\\);")
                      "int main(void) { return 77; }")))))))))))
   ;; libgpg-error 1.61's t-printf test expects %.100Lf with LDBL_MAX to fail.
   ;; armhf has no wider long double, so LDBL_MAX equals DBL_MAX.
   ((and (string=? (package-name base) "libgpg-error")
         (string=? (package-version base) "1.61"))
    (fix-or-substitute
     base system
     (package
       (inherit libgpg-error)
       (source
        (origin
          (inherit (package-source libgpg-error))
          (patches (append (origin-patches (package-source libgpg-error))
                           (list (local-file
                                  "../patches/libgpg-error-armhf-t-printf.patch")))))))))
   ;; Trio's test-only patch probes optional socket syscalls that 32-bit ARM
   ;; user emulation does not implement faithfully.
   ((and (string=? (package-name base) "python-trio")
         (string=? (package-version base) "0.33.0"))
    (fix-or-substitute
     base system
     (package
       (inherit base)
       (source
        (origin
          (inherit (package-source base))
          (patches
           (append (origin-patches (package-source base))
                   (list (local-file
                          "../patches/python-trio-socket-capabilities.patch")))))))))
   (else (fix-common-package base system))))

(define rewrite-armhf-packages
  (make-compilation-package-mapper
   (lambda (base) (fix-armhf-package base "armhf-linux"))))

(define rewrite-aarch64-packages
  (make-compilation-package-mapper
   (lambda (base) (fix-common-package base "aarch64-linux"))))

(define* (armhf-package-rewriter package #:key (system %system)
                                       (extra-mixed-packages '()))
  (rewrite-armhf-packages
   ((make-armhf-sdk-rewriter #:system system
                            #:extra-mixed-packages extra-mixed-packages)
    package)))

(define* (aarch64-package-rewriter package #:key (cortex-a53? #f) (system %system)
                                          (extra-mixed-packages '()))
  (rewrite-aarch64-packages
   ((make-aarch64-sdk-rewriter #:cortex-a53? cortex-a53? #:system system
                              #:extra-mixed-packages extra-mixed-packages)
    package)))

(define (native-image-tool-package base)
  "Force BASE to be built for the runner's native system.
Image-construction tools are executed by the runner, not by the target OS."
  (let* ((bs (package-build-system base))
         (native-bs
          (build-system
           (name (build-system-name bs))
           (description (build-system-description bs))
           (lower
            (lambda args
              (apply (build-system-lower bs)
                     (append (strip-keyword-arguments '(#:system #:target) args)
                             (list #:system %system #:target #f))))))))
    (package
      (inherit base)
      (build-system native-bs))))

(define %original-package-lower
  ((@@ (guix gexp) lookup-compiler) libgpg-error))
(define %original-package-expand
  ((@@ (guix gexp) lookup-expander) libgpg-error))

(define %image-builders-patched? #f)

(define (patch-image-builders!)
  (unless %image-builders-patched?
    (set! %image-builders-patched? #t)
    (define-gexp-compiler arm-package-compiler (struct-vtable libgpg-error)
      compiler => (lambda (package system target)
                    (%original-package-lower
                     (let ((destination (gnu-triplet->nix-system (or target system))))
                       (cond
                        ((string=? destination "armhf-linux")
                         (rewrite-armhf-packages package))
                        ((string=? destination "aarch64-linux")
                         (rewrite-aarch64-packages package))
                        (else
                         (fix-common-package package destination))))
                     system target))
      expander => %original-package-expand)

    ;; The image builder is executed by the runner.  Guix normally builds its
    ;; tools for --system, which makes an armhf image assemble its own qemu and
    ;; genimage under emulation.
    (module-set! (resolve-module '(gnu packages virtualization))
                 'qemu-minimal
                 (native-image-tool-package qemu-minimal))
    (module-set! (resolve-module '(gnu packages flashing-tools))
                 'genimage
                 (native-image-tool-package genimage))))

(define (rewrite-service services type rewrite)
  (map (lambda (s)
         (if (eq? type (service-kind s))
             (service type (rewrite (service-value s)))
             s))
       services))

(define* (with-arm-workarounds os
                               #:key
                               (package-rewriter identity)
                               (service-rewriter rewrite-armhf-packages))
  (patch-image-builders!)
  (operating-system
   (inherit os)
   (packages (map package-rewriter (operating-system-packages os)))
   (services
    (chain
     (operating-system-user-services os)
     (rewrite-service _ dbus-root-service-type
      (lambda (config)
        (dbus-configuration
         (inherit config)
         (dbus (service-rewriter
                ;; dbus-configuration-dbus is not exported.
                ((@@ (gnu services dbus) dbus-configuration-dbus)
                 config))))))
     (rewrite-service _ udev-service-type
      (lambda (config)
        (udev-configuration
         (inherit config)
         (udev (service-rewriter
                (udev-configuration-udev config))))))
     (rewrite-service _ avahi-service-type
      (lambda (config)
        (avahi-configuration
         (inherit config)
         (avahi (service-rewriter
                 (avahi-configuration-avahi config))))))
     (rewrite-service _ openssh-service-type
      (lambda (config)
        (openssh-configuration
         (inherit config)
         (openssh (service-rewriter
                   (openssh-configuration-openssh config))))))
     (rewrite-service _ prometheus-node-exporter-service-type
      (lambda (config)
        (prometheus-node-exporter-configuration
         (inherit config)
         (package (service-rewriter
                   (prometheus-node-exporter-configuration-package
                    config))))))
     (rewrite-service _ upsd-service-type
      (lambda (config)
        (upsd-configuration
         (inherit config)
         (package (service-rewriter
                   (upsd-configuration-package config))))))
     (rewrite-service _ spartan-sensor-mesh-service-type
      (lambda (config)
        (let ((nut (spartan-sensor-mesh-configuration-nut config)))
          (spartan-sensor-mesh-configuration
           (inherit config)
           (nut (and nut (service-rewriter nut)))))))))))


(define (with-extra-mixed-packages rewriter extra-mixed-packages)
  (if (null? extra-mixed-packages)
      rewriter
      (lambda (package)
        (rewriter package #:extra-mixed-packages extra-mixed-packages))))

(define* (with-armhf-workarounds os
                                  #:key
                                  (package-rewriter identity)
                                  (extra-mixed-packages '()))
  "Apply the ARM hard-float package fixes and select the armhf mixed-compilation policy.
EXTRA-MIXED-PACKAGES adds host-specific packages to the mixed-compilation policy."
  (with-arm-workarounds os
    #:package-rewriter (with-extra-mixed-packages package-rewriter extra-mixed-packages)
    #:service-rewriter (lambda (package)
                         (armhf-package-rewriter
                          package #:extra-mixed-packages extra-mixed-packages))))

(define* (with-aarch64-workarounds os #:key (package-rewriter identity)
                                          (extra-mixed-packages '()))
  "Apply the ARM package fixes and select the aarch64 mixed-compilation policy.
PACKAGE-REWRITER supplies the board's Guile policy, such as `rpi3-package'.
EXTRA-MIXED-PACKAGES adds host-specific packages to the mixed-compilation policy."
  (with-arm-workarounds os
    #:package-rewriter (with-extra-mixed-packages package-rewriter extra-mixed-packages)
    #:service-rewriter (lambda (package)
                         (aarch64-package-rewriter
                          package #:extra-mixed-packages extra-mixed-packages))))
