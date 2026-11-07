(define-module (spartan packages firmware)
  #:use-module (gnu packages base)
  #:use-module (guix build-system copy)
  #:use-module (guix gexp)
  #:use-module (guix download)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (nongnu packages linux)
  #:use-module (nonguix licenses)
  #:export (linux-firmware-uncompressed
            rpi3-bluetooth-firmware))

(define linux-firmware-uncompressed
  ;; Provide uncompressed firmware for generic kernels that lack firmware
  ;; compression support.  Nonguix's linux-firmware installs Zstd-compressed
  ;; blobs, which those kernels cannot load.
  (package
    (inherit linux-firmware)
    (name "linux-firmware-uncompressed")
    (arguments
     (substitute-keyword-arguments (package-arguments linux-firmware)
       ((#:phases phases)
        #~(modify-phases #$phases
            ;; Restore make install instead of Nonguix's make install-zst.
            (replace 'install (assoc-ref %standard-phases 'install))))))
    (synopsis "Uncompressed nonfree firmware blobs for Linux")
    (description
     "This package provides Nonguix's complete linux-firmware collection as
uncompressed files for kernels without firmware compression support.")))

(define rpi3-bluetooth-firmware
  (package
    (name "rpi3-bluetooth-firmware")
    (version "1.2-13")
    ;; Debian Trixie's package includes the Raspberry Pi firmware and license.
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "mirror://debian/pool/non-free-firmware/b/bluez-firmware/"
             "bluez-firmware_" version "_all.deb"))
       (sha256
        (base32 "09g8c7z6rb2bd62pjzcfrabv8c86m9sxdj8yz0achrr0z1pqifjd"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("usr/lib/firmware/brcm/BCM43430A1.hcd" "lib/firmware/brcm/")
          ;; This contains the plain-text Cypress license and attribution.
          ("usr/share/doc/bluez-firmware/copyright"
           "share/doc/rpi3-bluetooth-firmware/copyright"))
      #:phases
      #~(modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              (invoke "ar" "x" source "data.tar.xz")
              (invoke "tar" "xf" "data.tar.xz"
                      "./usr/lib/firmware/brcm/BCM43430A1.hcd"
                      "./usr/share/doc/bluez-firmware/copyright")))
          (add-after 'install 'add-board-alias
            (lambda _
              (symlink "BCM43430A1.hcd"
                       (string-append
                        #$output
                        "/lib/firmware/brcm/BCM43430A1.raspberrypi,3-model-b.hcd")))))))
    (native-inputs (list binutils))
    (home-page "https://packages.debian.org/trixie/bluez-firmware")
    (synopsis "Bluetooth firmware for Raspberry Pi 3 Model B")
    (description
     "This package provides the BCM43430A1 Bluetooth firmware from Debian's
bluez-firmware package, including the board-specific alias for Raspberry Pi 3
Model B.  The firmware is installed uncompressed for kernels without firmware
compression support.")
    (license (nonfree "file://usr/share/doc/bluez-firmware/copyright"))))
