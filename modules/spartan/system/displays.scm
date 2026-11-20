(define-module (spartan system displays)
  #:use-module (gnu bootloader)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (spartan packages displays)
  #:use-module (srfi srfi-1)
  #:export (with-seeedstudio-7inch-hdmi-display))

(define (display-bootloader base extra-config)
  (define (overlay files entries)
    (directory-union "rpi-seeedstudio-boot-files"
      (list (file-union "rpi-seeedstudio-display-config" entries) files)
      #:resolve-collision 'first))
  (define fragment "seeedstudio-7inch-hdmi.txt")
  (define fragment-entry
    (list fragment
          (file-append (if extra-config
                           (make-seeedstudio-7inch-hdmi-config #:extra-config extra-config)
                           seeedstudio-7inch-hdmi-config)
                       "/share/raspberrypi/" fragment)))
  (case (bootloader-name base)
    ((u-boot-rpi-arm64-seeedstudio-7inch)
     (if extra-config
         (bootloader
          (inherit base)
          (package (overlay (bootloader-package base) (list fragment-entry))))
         base))
    ((u-boot-rpi-arm64)
     (let* ((files (bootloader-package base))
            (config (computed-file "config.txt"
                      #~(begin
                          (use-modules (ice-9 textual-ports))
                          (call-with-output-file #$output
                            (lambda (port)
                              (display (call-with-input-file
                                           #$(file-append files "/config.txt") get-string-all)
                                       port)
                              (format port "~%[all]~%include ~a~%" #$fragment)))))))
       (bootloader
        (inherit base)
        (name 'u-boot-rpi-arm64-seeedstudio-7inch)
        (package (overlay files (list (list "config.txt" config) fragment-entry))))))
    (else (error "Seeed display requires the Spartan Raspberry Pi ARM64 bootloader"
                 (bootloader-name base)))))

(define* (with-seeedstudio-7inch-hdmi-display os #:key (rotation 270) extra-config)
  "Install the panel's firmware HDMI settings and request its mode in Linux.
ROTATION is in degrees and applies to the Linux video mode.
When supplied, append the list of EXTRA-CONFIG strings to the firmware settings."
  (unless (memv rotation '(0 90 180 270))
    (error "Seeed display rotation must be 0, 90, 180, or 270 degrees" rotation))
  (let ((configuration (operating-system-bootloader os))
        (arguments (operating-system-user-kernel-arguments os))
        ;; Use the VC4 connector name and the integer refresh DRM expects.
        (video (string-append "video=HDMI-A-1:720x1280@60,rotate="
                              (number->string rotation))))
    (operating-system
     (inherit os)
     (kernel-arguments
      (append (remove (lambda (argument)
                        (and (string? argument) (string-prefix? "video=HDMI-A-1:" argument)))
                      arguments)
              (list video)))
     (bootloader
      (bootloader-configuration
        (inherit configuration)
        (bootloader (display-bootloader
                      (bootloader-configuration-bootloader configuration)
                      extra-config)))))))
