(define-module (gnu system images raspberrypi)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu image)
  #:use-module (gnu packages bootloaders)
  #:use-module (gnu packages raspberry-pi)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system image)
  #:use-module (guix gexp)
  #:use-module (guix platforms arm)
  #:use-module (nongnu packages linux)
  #:use-module (spartan services file-systems)
  #:export (%rpi-root-file-system
            %rpi-boot-file-system
            %rpi-resize-file-system-service
            rpi-image-type
            rpi3-barebones-os
            rpi3-barebones-raw-image))

;; Guix discovers exported image types in this namespace when the channel is
;; installed. The SD layout is shared by compatible AArch64 Pi hosts; the
;; concrete barebones OS below supplies the Pi 3 boot chain and kernel.

(define %rpi-root-label "Guix")
(define %rpi-boot-label "PIBOOT")

(define %rpi-root-file-system
  (file-system
   (device (file-system-label %rpi-root-label))
   (mount-point "/")
   (type "ext4")))

(define %rpi-boot-file-system
  (file-system
   (device (file-system-label %rpi-boot-label))
   (mount-point "/boot/firmware")
   (type "vfat")))

(define %rpi-resize-file-system-service
  ;; Hosts include this service for both initial boot and later guix deploys.
  (service resize-file-system-service-type
           (resize-file-system-configuration
            (file-system %rpi-root-file-system))))

(define rpi-custom-config
  ;; Guix's config.txt includes this last, overriding its load-time choice
  ;; of ARM mode when evaluated on an x86 build machine.
  (raspi-custom-txt '("arm_64bit=1")))

(define rpi3-bootloader
  ;; The upstream chain is a blueprint without firmware or device trees.
  (efi-bootloader-chain
   grub-efi-netboot-removable-bootloader
   #:packages (list u-boot-rpi-arm64-efi-bin raspberrypi-firmware)
   #:files (list %raspi-config-txt
                 %raspi-bcm27-dtb-txt
                 %raspi-u-boot-bootloader-txt
                 rpi-custom-config)))

(define rpi3-barebones-os
  (operating-system
   (host-name "raspberrypi3")
   (timezone "Etc/UTC")
   (locale "en_US.utf8")
   (kernel linux-arm64-generic)
   (firmware (list linux-firmware))
   (initrd-modules '())
   (bootloader
    (bootloader-configuration
     (bootloader rpi3-bootloader)
     (targets (list (file-system-mount-point %rpi-boot-file-system)))))
   (file-systems
    (append (list %rpi-root-file-system %rpi-boot-file-system)
            %base-file-systems))
   (services
    (cons* (service dhcpcd-service-type)
           (service ntp-service-type)
           %rpi-resize-file-system-service
           %base-services))))

(define initialize-rpi-boot-partition
  ;; The generic ESP initializer installs GRUB alone. This partition needs the
  ;; complete firmware/U-Boot/GRUB profile supplied by the system bootloader.
  #~(lambda* (root #:key bootloader-package #:allow-other-keys)
      (mkdir-p root)
      (copy-recursively bootloader-package root #:follow-symlinks? #t)
      (mkdir-p (string-append root "/efi/boot"))
      (call-with-output-file (string-append root "/efi/boot/grub.cfg")
        (lambda (port)
          (display #$(string-append "search --label --set=root "
                                   %rpi-root-label
                                   "\nconfigfile /boot/grub/grub.cfg\n")
                   port)))))

(define rpi-image-type
  (image-type
   (name 'rpi-raw)
   (constructor
    (lambda (os)
      (image
       (name 'rpi-raw)
       (format 'disk-image)
       (platform aarch64-linux)
       (operating-system os)
       (partition-table-type 'mbr)
       (volatile-root? #f)
       (partitions
        (list
         (partition
          (size (* 256 (expt 2 20)))
          (offset root-offset)
          (label %rpi-boot-label)
          (file-system "fat32")
          ;; No 'esp flag: the Pi ROM needs an ordinary FAT partition type,
          ;; not MBR type 0xEF. /boot/firmware also survives Guix image's OS
          ;; rewriting without an ESP flag (unlike the special /boot/efi).
          (initializer initialize-rpi-boot-partition))
         (partition
          (inherit root-partition)
          (label %rpi-root-label)))))))))

(define rpi3-barebones-raw-image
  (image
   (inherit
    (os+platform->image rpi3-barebones-os aarch64-linux
                        #:type rpi-image-type))
   (name 'rpi3-barebones-raw-image)))

;; Like Guix's board image modules, this file can be built directly.
rpi3-barebones-raw-image
