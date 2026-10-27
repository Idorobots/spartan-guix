(define-module (gnu system images raspberrypi)
  #:use-module (gnu bootloader)
  #:use-module (gnu image)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system image)
  #:use-module (guix gexp)
  #:use-module (guix platforms arm)
  #:use-module (nongnu packages linux)
  #:use-module (spartan bootloader raspberrypi)
  #:use-module (spartan packages guile)
  #:use-module (spartan packages ntp)
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

(define rpi3-barebones-os
  (operating-system
   (host-name "raspberrypi3")
   (timezone "Etc/UTC")
   (locale "en_US.utf8")
   (kernel linux-arm64-generic)
   (firmware (list linux-firmware))
   (initrd-modules '())
   (packages (map package-with-cortex-a53-guile %base-packages))
   (essential-services
    (modify-services (operating-system-default-essential-services this-operating-system)
      (shepherd-root-service-type config =>
        (shepherd-configuration
         (inherit config)
         (shepherd (package-with-cortex-a53-guile
                    (shepherd-configuration-shepherd config)))))))
   (bootloader
    (bootloader-configuration
     (bootloader u-boot-rpi-arm64-bootloader)
     (targets (list (file-system-mount-point %rpi-boot-file-system)))))
   (file-systems
    (append (list %rpi-root-file-system %rpi-boot-file-system)
            %base-file-systems))
   (services
    (cons* (service dhcpcd-service-type)
           (service openntpd-service-type
                    (openntpd-configuration
                     (openntpd openntpd/cross-fixed)))
           %rpi-resize-file-system-service
           (modify-services %base-services
             (guix-service-type config =>
               (guix-configuration
                (inherit config)
                (guix (package-with-cortex-a53-guile
                       (guix-configuration-guix config))))))))))

(define initialize-rpi-boot-partition
  ;; Firmware and U-Boot live on FAT. Guix installs extlinux.conf on root.
  #~(lambda* (root #:key bootloader-package #:allow-other-keys)
      (#$install-rpi-boot-files bootloader-package root)))

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

rpi3-barebones-raw-image
