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
  #:use-module ((guix config) #:select (%system))
  #:use-module (guix gexp)
  #:use-module (guix platforms arm)
  #:use-module (nongnu packages linux)
  #:use-module (spartan bootloader raspberrypi)
  #:use-module (spartan packages firmware)
  #:use-module (spartan packages mixed)
  #:use-module (spartan packages raspberrypi)
  #:use-module (spartan system arm-workarounds)
  #:use-module (spartan services file-systems)
  #:re-export (rpi2-package rpi3-package rpi4-package rpi3-guile-fixes)
  #:export (%rpi-root-file-system
            %rpi-boot-file-system
            %rpi-resize-file-system-service
            rpi-image-type
            rpi2-image-type
            rpi2-barebones-os
            rpi2-barebones-raw-image
            rpi3-barebones-os
            rpi3-barebones-raw-image
            rpi4-image-type
            rpi4-barebones-os
            rpi4-barebones-raw-image))

;; Guix discovers exported image types in this namespace when the channel is
;; installed. Pi 2 (ARMv7), Pi 3 and Pi 4 (AArch64) share the SD layout,
;; mounts and resize service.

(define %rpi-root-label "Guix")
(define %rpi-boot-label "PIBOOT")

(define (rpi-essential-services os rewrite-package)
  (modify-services (operating-system-default-essential-services os)
    (shepherd-root-service-type config =>
      (shepherd-configuration
       (inherit config)
       (shepherd (rewrite-package (shepherd-configuration-shepherd config)))))))

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

(define (rpi-services rewrite-package)
  (cons* (service dhcpcd-service-type)
         (service ntp-service-type)
         %rpi-resize-file-system-service
         (modify-services %base-services
           (guix-service-type config =>
             (let ((guix (rewrite-package (guix-configuration-guix config))))
               (guix-configuration
                (inherit config)
                (guix guix)
                ;; Keep trust files on the same routed Guix package, rather
                ;; than pulling a second, unadapted Guix into the image.
                (authorized-keys
                 (list (file-append guix "/share/guix/berlin.guix.gnu.org.pub")
                       (file-append guix "/share/guix/bordeaux.guix.gnu.org.pub")))))))))

;; Pi 2 Model B v1.0/v1.1: BCM2836, Cortex-A7, 32-bit ARMv7 hard float.
(define rpi2-barebones-os-base
  (operating-system
   (host-name "raspberrypi2")
   (timezone "Etc/UTC")
   (locale "en_US.utf8")
   (kernel (package-with-compilation-system linux-rpi2))
   (kernel-arguments
    (append '("console=ttyAMA0,115200" "console=tty1")
            %default-kernel-arguments))
   ;; Include runtime blobs for attached devices as well as boot firmware.
   (firmware (cons (package-with-compilation-system linux-firmware-uncompressed)
                   %base-firmware))
   ;; multi_v7_defconfig builds the Pi's SD host and ext4 drivers in.
   (initrd-modules '())
   (packages %base-packages)
   (essential-services
    (rpi-essential-services this-operating-system rpi2-package))
   (bootloader
    (bootloader-configuration
     (bootloader u-boot-rpi-2-bootloader)
     (targets (list (file-system-mount-point %rpi-boot-file-system)))))
   (file-systems
    (append (list %rpi-root-file-system %rpi-boot-file-system)
            %base-file-systems))
   (services (rpi-services rpi2-package))))

(define rpi2-barebones-os
  (with-armhf-workarounds rpi2-barebones-os-base
    #:package-rewriter rpi2-package))

(define rpi3-barebones-os-base
  (operating-system
   (host-name "raspberrypi3")
   (timezone "Etc/UTC")
   (locale "en_US.utf8")
   ;; Pi 3 and Pi 4 Model B share this kernel. On upgrades, check the resolved
   ;; .config (or /proc/config.gz), since defconfig omits Kconfig defaults.
   ;;
   ;; SD root has no storage modules in the initrd: CONFIG_ARCH_BCM2835=y,
   ;; CONFIG_MMC=y, CONFIG_MMC_BLOCK=y and CONFIG_EXT4_FS=y. The Pi 3 needs
   ;; CONFIG_MMC_BCM2835=y; the Pi 4's BCM2711 eMMC2 controller needs
   ;; CONFIG_MMC_SDHCI_IPROC=y (defaults to y with CONFIG_ARCH_BCM_IPROC=y
   ;; in Linux 7.2). Also check CONFIG_VFAT_FS for /boot/firmware.
   ;;
   ;; Ethernet (y or m): Pi 3 uses CONFIG_USB_DWC2 in host-capable mode,
   ;; CONFIG_USB_USBNET and CONFIG_USB_NET_SMSC95XX. Pi 4 uses CONFIG_BCMGENET
   ;; and CONFIG_BROADCOM_PHY.
   ;; Wi-Fi: CONFIG_BRCMFMAC=m (or y), CONFIG_BRCMFMAC_SDIO=y,
   ;; CONFIG_PWRSEQ_SIMPLE and CONFIG_FW_LOADER.
   ;; Bluetooth: CONFIG_BT and CONFIG_BT_HCIUART (y or m),
   ;; CONFIG_BT_HCIUART_SERDEV=y and CONFIG_BT_HCIUART_BCM=y.
   ;; Keep the board-specific DTBs and radio firmware available too.
   (kernel (package-with-compilation-system linux-arm64-generic))
   ;; Firmware-side WPA handshakes time out on the Pi 3. Let wpa_supplicant
   ;; handle them instead; bit 13 disables brcmfmac's FWSUP feature.
   (kernel-arguments (cons "brcmfmac.feature_disable=0x2000"
                           %default-kernel-arguments))
   ;; On a native-output miss, install the blobs with runner-native tools.
   (firmware (cons* (package-with-compilation-system linux-firmware-uncompressed)
                    rpi3-bluetooth-firmware
                    %base-firmware))
   (initrd-modules '())
   (packages %base-packages)
   (essential-services
    (rpi-essential-services this-operating-system rpi3-package))
   (bootloader
    (bootloader-configuration
     (bootloader u-boot-rpi-arm64-bootloader)
     (targets (list (file-system-mount-point %rpi-boot-file-system)))))
   (file-systems
    (append (list %rpi-root-file-system %rpi-boot-file-system)
            %base-file-systems))
   (services (rpi-services rpi3-package))))

(define rpi3-barebones-os
  (with-aarch64-workarounds rpi3-barebones-os-base
    #:package-rewriter rpi3-package))

(define rpi4-barebones-os-base
  (operating-system
   (inherit rpi3-barebones-os-base)
   (host-name "raspberrypi4")
   (kernel-arguments %default-kernel-arguments)
   (firmware (cons* (package-with-compilation-system linux-firmware-uncompressed)
                    rpi4-bluetooth-firmware
                    %base-firmware))
   (packages %base-packages)
   (essential-services
    (rpi-essential-services this-operating-system rpi4-package))
   (services (rpi-services rpi4-package))))

(define rpi4-barebones-os
  (with-aarch64-workarounds rpi4-barebones-os-base
    #:package-rewriter rpi4-package))

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

(define rpi2-image-type
  (image-type
   (name 'rpi2-raw)
   (constructor
    (lambda (os)
      (image
       (inherit (os->image os #:type rpi-image-type))
       (name 'rpi2-raw)
       (platform armv7-linux))))))

(define rpi4-image-type
  (image-type
   (name 'rpi4-raw)
   (constructor
    (lambda (os)
      (image
       (inherit (os->image os #:type rpi-image-type))
       (name 'rpi4-raw))))))

(define rpi2-barebones-raw-image
  (image
   (inherit (os->image rpi2-barebones-os #:type rpi2-image-type))
   (name 'rpi2-barebones-raw-image)))

(define rpi3-barebones-raw-image
  (image
   (inherit (os->image rpi3-barebones-os #:type rpi-image-type))
   (name 'rpi3-barebones-raw-image)))

(define rpi4-barebones-raw-image
  (image
   (inherit (os->image rpi4-barebones-os #:type rpi4-image-type))
   (name 'rpi4-barebones-raw-image)))

rpi3-barebones-raw-image
