(use-modules (gnu)
             (gnu bootloader u-boot)
             (gnu image)
             (gnu packages raspberry-pi)
             (gnu packages ntp)
             (gnu services networking)
             (gnu services ssh)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix build utils)
             (guix gexp)
             (guix packages)
             (ice-9 textual-ports)
             (spartan bootloader raspberrypi)
             (spartan services file-systems)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "raspberrypi")

(define root (dirname (dirname (canonicalize-path (current-filename)))))
(define direct-image
  (save-module-excursion
   (lambda ()
     (load (string-append root "/modules/gnu/system/images/raspberrypi.scm")))))
(define img (os->image rpi3-barebones-os #:type rpi-image-type))
(define converted (operating-system-for-image img))

(define (service-of-type os type)
  (find (lambda (value) (eq? (service-kind value) type))
        (operating-system-user-services os)))

(test-equal "barebones OS adds only DHCP, reference NTP and resizing to base services"
  (append (list dhcpcd-service-type ntp-service-type
                resize-file-system-service-type)
          (map service-kind %base-services))
  (map service-kind (operating-system-user-services rpi3-barebones-os)))

(test-assert "barebones and converted images retain stock NTP with large initial adjustments"
  (every
   (lambda (system)
     (let* ((time-services
             (filter (lambda (s) (eq? (service-kind s) ntp-service-type))
                     (operating-system-user-services system)))
            (config (and (= 1 (length time-services))
                         (service-value (car time-services)))))
       (and config (eq? ntp (ntp-configuration-ntp config))
            (ntp-allow-large-adjustment? config)
            (not (service-of-type system openntpd-service-type)))))
   (list rpi3-barebones-os converted)))

(test-assert "barebones and image-converted service graphs resolve"
  (every (lambda (system)
           (service? (fold-services (operating-system-services system))))
         (list rpi3-barebones-os converted)))

(test-assert "direct module evaluation returns the concrete barebones Pi 3 image"
  (and (image? direct-image)
       (eq? (image-name direct-image) 'rpi3-barebones-raw-image)
       (eq? (image-operating-system direct-image) rpi3-barebones-os)
       (equal? (map partition-label (image-partitions direct-image))
               '("PIBOOT" "Guix"))
       (not (image-volatile-root? direct-image))))

(test-equal "raw SD image uses MBR and persistent root" '(disk-image mbr #f)
  (list (image-format img) (image-partition-table-type img)
        (image-volatile-root? img)))

(test-equal "first partition is ordinary FAT32, last is growable ext4"
  '(("PIBOOT" "fat32" ()) ("Guix" "ext4" (boot)))
  (map (lambda (p) (list (partition-label p) (partition-file-system p)
                        (partition-flags p)))
       (image-partitions img)))

(test-equal "firmware partition reserves 256 MiB" (* 256 (expt 2 20))
  (partition-size (car (image-partitions img))))

(test-assert "boot mount matches the image partition before and after conversion"
  (every
   (lambda (system)
     (find (lambda (fs)
             (and (string=? "/boot/firmware" (file-system-mount-point fs))
                  (equal? (file-system-label
                           (partition-label (car (image-partitions img))))
                          (file-system-device fs))))
           (operating-system-file-systems system)))
   (list rpi3-barebones-os converted)))

(test-assert "root resize resolves the image root by label after conversion"
  (every
   (lambda (system)
     (let* ((config (service-value
                     (service-of-type system resize-file-system-service-type)))
            (fs (resize-file-system-configuration-file-system config)))
       (and (string=? "/" (file-system-mount-point fs))
            (string=? "ext4" (file-system-type fs))
            (equal? (file-system-device fs)
                    (file-system-label (partition-label
                                        (last (image-partitions img))))))))
   (list rpi3-barebones-os converted)))

(test-assert "upstream config loads the explicit AArch64 override last"
  (and (string-suffix? "include custom.txt\n" (plain-file-content %raspi-config-txt))
       (string=? "arm_64bit=1\n"
                 (plain-file-content
                   (@@ (spartan bootloader raspberrypi) rpi-custom-config)))))

(define boot-config (operating-system-bootloader rpi3-barebones-os))
(define pi-bootloader (bootloader-configuration-bootloader boot-config))

(test-assert "Pi bootloader uses Guix's Extlinux generator and file-based installation"
  (and (eq? pi-bootloader u-boot-rpi-arm64-bootloader)
       (eq? (bootloader-configuration-file-generator pi-bootloader)
            (bootloader-configuration-file-generator u-boot-bootloader))
       (string=? "/boot/extlinux/extlinux.conf"
                 (bootloader-configuration-file pi-bootloader))
       (equal? '("/boot/firmware") (bootloader-configuration-targets boot-config))
       (not (bootloader-disk-image-installer pi-bootloader))))

;; Execute the selected generator with distinct generation paths. Only the
;; output filename needs approximation; no store or kernel build is required.
(define config-output (make-parameter #f))
(define (*approximate*) (config-output))
(define (expand-gexps value)
  ;; The approximation helper leaves spliced lists of gexps unexpanded.
  (cond ((gexp? value) (expand-gexps (gexp->approximate-sexp value)))
        ((pair? value) (map expand-gexps value))
        (else value)))
(define extlinux-text
  (let* ((directory (mkdtemp "/tmp/spartan-extlinux-test-XXXXXX"))
         (file (string-append directory "/extlinux.conf"))
         (generate (bootloader-configuration-file-generator pi-bootloader))
         (config (generate
                  boot-config
                  (list (menu-entry
                         (label "current")
                         (linux "/gnu/store/current-kernel/Image")
                         (initrd "/gnu/store/current-initrd/initrd")
                         (linux-arguments '("root=LABEL=Guix" "--system=/gnu/store/current-system"))))
                  #:old-entries
                  (list (menu-entry
                         (label "previous")
                         (linux "/gnu/store/previous-kernel/Image")
                         (initrd "/gnu/store/previous-initrd/initrd")
                         (linux-arguments '("root=LABEL=Guix" "--system=/gnu/store/previous-system")))))))
    (dynamic-wind
      (const #t)
      (lambda ()
        (parameterize ((config-output file))
          (eval (expand-gexps (computed-file-gexp config)) (current-module)))
        (call-with-input-file file get-string-all))
      (lambda () (delete-file-recursively directory)))))

(test-assert "Extlinux loads the current kernel, initrd, arguments and matching DTB directory"
  (every (lambda (line) (string-contains extlinux-text line))
         '("LABEL current\n"
           "KERNEL /gnu/store/current-kernel/Image\n"
           "INITRD /gnu/store/current-initrd/initrd\n"
           "FDTDIR /gnu/store/current-kernel/lib/dtbs\n"
           "APPEND root=LABEL=Guix --system=/gnu/store/current-system\n")))

(test-assert "Extlinux retains the previous generation's own kernel and initrd"
  (every (lambda (line) (string-contains extlinux-text line))
         '("LABEL previous\n"
           "KERNEL /gnu/store/previous-kernel/Image\n"
           "INITRD /gnu/store/previous-initrd/initrd\n"
           "FDTDIR /gnu/store/previous-kernel/lib/dtbs\n"
           "APPEND root=LABEL=Guix --system=/gnu/store/previous-system\n")))

(test-equal "Wi-Fi-capable kernel is selected" "linux-arm64-generic"
  (package-name (operating-system-kernel rpi3-barebones-os)))

(test-assert "barebones image needs no management keys or Wi-Fi credentials"
  (and (not (service-of-type rpi3-barebones-os openssh-service-type))
       (not (service-of-type rpi3-barebones-os wpa-supplicant-service-type))))

;; Execute the real initializer without a daemon or a disk image. Firmware
;; symlinks must become regular files because the boot partition is FAT.
(test-assert "image initializer materializes firmware, U-Boot and nested symlinks for FAT"
  (let* ((directory (mkdtemp "/tmp/spartan-rpi-test-XXXXXX"))
         (profile (string-append directory "/profile"))
         (boot (string-append directory "/boot"))
         (payload (string-append directory "/firmware")))
    (dynamic-wind
      (lambda ()
         (mkdir profile)
         (mkdir (string-append profile "/overlays"))
         (call-with-output-file payload (lambda (port) (display "firmware" port)))
         (for-each (lambda (name) (symlink payload (string-append profile name)))
                   '("/start.elf" "/u-boot.bin" "/overlays/test.dtbo")))
      (lambda ()
        (let ((initialize
               (eval (gexp->approximate-sexp
                      (partition-initializer (car (image-partitions img))))
                     (current-module))))
          (initialize boot #:bootloader-package profile)
           (every (lambda (name)
                    (let ((file (string-append boot name)))
                      (and (eq? 'regular (stat:type (lstat file)))
                           (string=? "firmware" (call-with-input-file file get-string-all)))))
                  '("/start.elf" "/u-boot.bin" "/overlays/test.dtbo"))))
      (lambda () (delete-file-recursively directory)))))

(test-assert "deployment installer refreshes boot files under the installation root"
  (let* ((directory (mkdtemp "/tmp/spartan-boot-install-test-XXXXXX"))
         (source (string-append directory "/source"))
         (mount-point (string-append directory "/system"))
         (target "/boot/firmware")
         (installed (string-append mount-point target "/u-boot.bin"))
         (install (eval (gexp->approximate-sexp (bootloader-installer pi-bootloader))
                        (current-module))))
    (dynamic-wind
      (lambda ()
        (mkdir source)
        (mkdir-p (string-append mount-point target))
        (call-with-output-file (string-append source "/u-boot.bin")
          (lambda (port) (display "updated U-Boot" port)))
        (call-with-output-file installed (lambda (port) (display "old U-Boot" port))))
      (lambda ()
        (install source target mount-point)
        (string=? "updated U-Boot" (call-with-input-file installed get-string-all)))
      (lambda () (delete-file-recursively directory)))))

(test-assert "root-image initialization leaves firmware copying to the FAT initializer"
  (let ((install (eval (gexp->approximate-sexp (bootloader-installer pi-bootloader))
                       (current-module))))
    (install "/nonexistent-boot-files" #f "/nonexistent-root")
    #t))

(define runner (test-runner-current))
(test-end "raspberrypi")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
