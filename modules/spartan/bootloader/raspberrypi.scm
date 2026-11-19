(define-module (spartan bootloader raspberrypi)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader u-boot)
  #:use-module (gnu packages bootloaders)
  #:use-module (gnu packages raspberry-pi)
  #:use-module (guix gexp)
  #:use-module (nongnu packages linux)
  #:export (u-boot-rpi-2-bootloader
            u-boot-rpi-arm64-bootloader
            install-rpi-boot-files))

(define rpi2-config
  ;; Independent of the machine evaluating this module. The v1 Pi 2 has
  ;; Cortex-A7 cores and must enter the 32-bit rpi_2 U-Boot build.
  (raspi-config-file "config.txt"
                     '("arm_64bit=0"
                       "enable_uart=1"
                       "device_tree=bcm2709-rpi-2-b.dtb"
                       "kernel=u-boot.bin")))

(define rpi2-boot-files
  (directory-union
   "rpi2-boot-files"
   (list raspberrypi-firmware
         u-boot-rpi-2-bin
         (file-union "rpi2-config" `(("config.txt" ,rpi2-config))))))

(define rpi-custom-config
  ;; The upstream config is constructed when its module is loaded, possibly
  ;; on x86-64. Its final include must select 64-bit mode explicitly.
  (raspi-custom-txt '("arm_64bit=1")))

(define rpi-boot-files
  (directory-union
   "rpi-arm64-boot-files"
   (list raspberrypi-firmware
         u-boot-rpi-arm64-bin
         (file-union "rpi-arm64-config"
                     `(("config.txt" ,%raspi-config-txt)
                       ("dtb.txt" ,%raspi-bcm27-dtb-txt)
                       ("bootloader.txt" ,%raspi-u-boot-bootloader-txt)
                       ("custom.txt" ,rpi-custom-config))))))

(define install-rpi-boot-files
  ;; Shared by the FAT image initializer and the on-device installer.
  (with-imported-modules '((guix build utils))
    #~(lambda (source target)
        (use-modules (guix build utils))
        (mkdir-p target)
        (copy-recursively source target #:follow-symlinks? #t))))

(define install-rpi-bootloader
  #~(lambda (bootloader target mount-point)
      ;; Image creation populates FAT separately; this call initializes root.
      (when target
        (let ((mounted-target (string-append mount-point target)))
          (#$install-rpi-boot-files
           bootloader
           (if (file-exists? mounted-target) mounted-target target))))))

(define u-boot-rpi-arm64-bootloader
  (bootloader
   (inherit u-boot-bootloader)
   (name 'u-boot-rpi-arm64)
   (package rpi-boot-files)
   (installer install-rpi-bootloader)
   ;; The Pi firmware reads u-boot.bin from FAT, not raw sectors.
   (disk-image-installer #f)))

(define u-boot-rpi-2-bootloader
  (bootloader
   (inherit u-boot-rpi-arm64-bootloader)
   (name 'u-boot-rpi-2)
   (package rpi2-boot-files)))
