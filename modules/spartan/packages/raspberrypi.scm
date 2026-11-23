(define-module (spartan packages raspberrypi)
  #:use-module (gnu packages linux)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module ((nongnu packages linux) #:select (corrupt-linux))
  #:export (linux-arm-generic linux-rpi2))

(define linux-arm-generic
  ;; Retain Guix's ARMv7 configuration, but use Nonguix's unmodified Linux
  ;; source and firmware-loading support, just like linux-arm64-generic.
  (corrupt-linux linux-libre-arm-generic #:name "linux-arm-generic"))

(define install-rpi2-device-tree-alias
  #~(lambda* (#:key outputs #:allow-other-keys)
      ;; 32-bit RPi U-Boot requests an unqualified fdtfile.  Kernel builds
      ;; disagree on whether DTBs are installed flat or below their vendor
      ;; directory, so accept both layouts and only add an alias when needed.
      (with-directory-excursion
          (string-append (assoc-ref outputs "out") "/lib/dtbs")
        (let ((alias "bcm2836-rpi-2-b.dtb")
              (vendored "broadcom/bcm2836-rpi-2-b.dtb"))
          (cond
           ((file-exists? alias) #t)
           ((file-exists? vendored) (symlink vendored alias))
           (else
            (error "Pi 2 kernel device tree is missing (looked for flat or vendor layout)"
                   alias vendored)))))))

(define linux-rpi2
  (package
   (inherit linux-arm-generic)
   (name "linux-rpi2")
   (arguments
    (substitute-keyword-arguments (package-arguments linux-arm-generic)
      ((#:phases phases)
       #~(modify-phases #$phases
           (add-after 'install 'expose-rpi2-device-tree
              #$install-rpi2-device-tree-alias)))))))
