(use-modules (gnu)
             (gnu image)
             (gnu packages raspberry-pi)
             (gnu services networking)
             (gnu services ssh)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix build utils)
             (guix gexp)
             (guix packages)
             (ice-9 textual-ports)
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

(test-equal "barebones OS adds only DHCP, OpenNTPD and resizing to base services"
  (append (list dhcpcd-service-type openntpd-service-type
                resize-file-system-service-type)
          (map service-kind %base-services))
  (map service-kind (operating-system-user-services rpi3-barebones-os)))

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
                  (@@ (gnu system images raspberrypi) rpi-custom-config)))))

(test-equal "Wi-Fi-capable kernel is selected" "linux-arm64-generic"
  (package-name (operating-system-kernel rpi3-barebones-os)))

(test-assert "barebones image needs no management keys or Wi-Fi credentials"
  (and (not (service-of-type rpi3-barebones-os openssh-service-type))
       (not (service-of-type rpi3-barebones-os wpa-supplicant-service-type))))

;; Execute the real initializer without a daemon or a disk image. Firmware
;; symlinks must become regular files because the boot partition is FAT.
(test-assert "boot initializer dereferences the profile and finds root GRUB config"
  (let* ((directory (mkdtemp "/tmp/spartan-rpi-test-XXXXXX"))
         (profile (string-append directory "/profile"))
         (boot (string-append directory "/boot"))
         (payload (string-append directory "/firmware")))
    (dynamic-wind
      (lambda ()
        (mkdir profile)
        (call-with-output-file payload (lambda (port) (display "firmware" port)))
        (symlink payload (string-append profile "/start.elf")))
      (lambda ()
        (let ((initialize
               (eval (gexp->approximate-sexp
                      (partition-initializer (car (image-partitions img))))
                     (current-module))))
          (initialize boot #:bootloader-package profile)
          (and (eq? 'regular (stat:type (lstat (string-append boot "/start.elf"))))
               (string-contains
                (call-with-input-file (string-append boot "/efi/boot/grub.cfg")
                  get-string-all)
                "search --label --set=root Guix\nconfigfile /boot/grub/grub.cfg"))))
      (lambda () (delete-file-recursively directory)))))

(define runner (test-runner-current))
(test-end "raspberrypi")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
