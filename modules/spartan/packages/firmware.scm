(define-module (spartan packages firmware)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix download)
  #:use-module (guix packages)
  #:use-module (nongnu packages linux)
  #:use-module (nonguix licenses)
  #:export (rpi3-wifi-firmware
            rpi3-bluetooth-firmware))

(define rpi3-wifi-firmware
  ;; Provide uncompressed firmware for generic kernels that lack firmware
  ;; compression support.  Nonguix's linux-firmware installs Zstd-compressed
  ;; blobs, which those kernels cannot load.
  (package
    (name "rpi3-wifi-firmware")
    (version (package-version linux-firmware))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((firmware (string-append #$linux-firmware "/lib/firmware/brcm/"))
                (destination (string-append #$output "/lib/firmware/brcm/"))
                (licenses (string-append
                           #$linux-firmware
                           #$(string-append "/share/doc/linux-firmware-" version)))
                (documentation (string-append
                                #$output
                                #$(string-append "/share/doc/" name "-" version))))
            (mkdir-p destination)
            (for-each
             (lambda (file)
               (invoke #+(file-append zstd "/bin/zstd") "--decompress"
                       ;; Broadcom names can alias Cypress payloads; zstd
                       ;; otherwise skips symbolic-link inputs.
                       (canonicalize-path (string-append firmware file ".zst"))
                       "-o" (string-append destination file)))
             '("brcmfmac43430-sdio.bin"
               "brcmfmac43430-sdio.raspberrypi,3-model-b.txt"
               "brcmfmac43430-sdio.clm_blob"))
            (for-each
             (lambda (file)
               (install-file (string-append licenses "/" file) documentation))
             '("LICENCE.broadcom_bcm43xx" "LICENCE.cypress"))))))
    (inputs (list linux-firmware))
    (native-inputs (list zstd))
    (home-page (package-home-page linux-firmware))
    (synopsis "Uncompressed Wi-Fi firmware for Raspberry Pi 3 Model B")
    (description
     "This package provides the Raspberry Pi 3 Model B's BCM43430 Wi-Fi
firmware, board configuration and regulatory blob as uncompressed files.  It
decompresses the corresponding files from Nonguix's linux-firmware for kernels
without firmware compression support.")
    (license (package-license linux-firmware))))

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
