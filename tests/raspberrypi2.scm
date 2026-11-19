(use-modules (gnu)
             (gnu bootloader u-boot)
             (gnu image)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix build utils)
             (guix gexp)
             (guix packages)
             (guix platform)
             (spartan bootloader raspberrypi)
             (spartan packages firmware)
             (spartan packages mixed)
             (spartan packages raspberrypi)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "raspberrypi2")

(define img rpi2-barebones-raw-image)
(define converted (operating-system-for-image img))
(define boot-config (operating-system-bootloader converted))
(define loader (bootloader-configuration-bootloader boot-config))

(test-equal "Pi 2 image selects ARMv7 hard float, including named image conversion"
  '("armhf-linux" "armhf-linux")
  (map (compose platform-system image-platform)
       (list img (os->image rpi2-barebones-os #:type rpi2-image-type))))

(test-equal "Pi 2 shares persistent MBR storage with growable ext4 last"
  '(mbr #f (("PIBOOT" "fat32") ("Guix" "ext4")))
  (list (image-partition-table-type img) (image-volatile-root? img)
        (map (lambda (p) (list (partition-label p) (partition-file-system p)))
             (image-partitions img))))

(test-assert "barebones and converted Pi 2 service graphs resolve"
  (every (lambda (os)
           (service? (fold-services (operating-system-services os))))
         (list rpi2-barebones-os converted)))

(test-assert "Pi 2 firmware mode and DTB are independent of the evaluator's architecture"
  (let ((text (plain-file-content
               (@@ (spartan bootloader raspberrypi) rpi2-config))))
    (every (lambda (line) (string-contains text line))
           '("arm_64bit=0\n" "device_tree=bcm2709-rpi-2-b.dtb\n"
             "kernel=u-boot.bin\n"))))

(test-assert "Pi 2 deployment and image conversion retain file-based Extlinux installation"
  (and (eq? loader u-boot-rpi-2-bootloader)
       (eq? (bootloader-configuration-file-generator loader)
            (bootloader-configuration-file-generator u-boot-bootloader))
       (equal? '("/boot/firmware") (bootloader-configuration-targets boot-config))
       (not (bootloader-disk-image-installer loader))))

(test-equal "kernel targets ARMv7 only" '("armhf-linux")
  (package-supported-systems linux-rpi2))

(test-assert "Pi 2 boots upstream Linux with firmware-loading support after image conversion"
  (every
   (lambda (os)
     (let* ((kernel (operating-system-kernel os))
            (source (package-source kernel)))
       (and (eq? kernel (package-with-compilation-system linux-rpi2))
            (string-prefix? "mirror://kernel.org/linux/kernel/" (origin-uri source))
            (not (origin-snippet source)))))
   (list rpi2-barebones-os converted)))

(test-assert "Pi 2 retains loadable uncompressed runtime firmware after image conversion"
  (every
   (lambda (os)
     (every (lambda (firmware) (memq firmware (operating-system-firmware os)))
            (cons (package-with-compilation-system linux-firmware-uncompressed)
                  %base-firmware)))
   (list rpi2-barebones-os converted)))

;; Exercise the actual kernel installation phase against an installed-DTB
;; fixture, so a U-Boot/kernel path mismatch fails before a board boot attempt.
(define install-alias
  (eval (gexp->approximate-sexp
         (@@ (spartan packages raspberrypi) install-rpi2-device-tree-alias))
        (current-module)))

(test-assert "U-Boot's unqualified DTB resolves to the kernel's board description"
  (let* ((directory (mkdtemp "/tmp/spartan-rpi2-dtb-XXXXXX"))
         (dtbs (string-append directory "/lib/dtbs")))
    (dynamic-wind
      (lambda ()
        (mkdir-p (string-append dtbs "/broadcom"))
        (call-with-output-file (string-append dtbs "/broadcom/bcm2836-rpi-2-b.dtb")
          (lambda (port) (display "Pi 2 DTB" port))))
      (lambda ()
        (install-alias #:outputs `(("out" . ,directory)))
        (string=? (canonicalize-path (string-append dtbs "/bcm2836-rpi-2-b.dtb"))
                  (string-append dtbs "/broadcom/bcm2836-rpi-2-b.dtb")))
      (lambda () (delete-file-recursively directory)))))

(test-error "kernel installation fails when the board DTB is absent" #t
  (let ((directory (mkdtemp "/tmp/spartan-rpi2-missing-dtb-XXXXXX")))
    (dynamic-wind
      (lambda () (mkdir-p (string-append directory "/lib/dtbs")))
      (lambda () (install-alias #:outputs `(("out" . ,directory))))
      (lambda () (delete-file-recursively directory)))))

(define runner (test-runner-current))
(test-end "raspberrypi2")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
