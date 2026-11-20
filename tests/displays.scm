(use-modules (gnu bootloader)
             (gnu system)
             (gnu system images raspberrypi)
             (guix build utils)
             (guix derivations)
             (guix gexp)
             (guix monads)
             (guix store)
             (ice-9 textual-ports)
             (spartan system displays)
             (srfi srfi-64))

(test-begin "displays")
(define runner (test-runner-current))

(define base-config "include custom.txt\n")
(define base
  (operating-system
   (inherit rpi3-barebones-os)
   (bootloader
    (let ((configuration (operating-system-bootloader rpi3-barebones-os)))
      (bootloader-configuration
       (inherit configuration)
       (bootloader
        (bootloader
         (inherit (bootloader-configuration-bootloader configuration))
         (package (file-union "rpi-boot-fixture"
                    `(("config.txt" ,(plain-file "config.txt" base-config))
                      ("custom.txt" ,(plain-file "custom.txt" "arm_64bit=1\n"))
                      ("u-boot.bin" ,(plain-file "u-boot.bin" "bootloader"))))))))))))

(define (system-bootloader os)
  (bootloader-configuration-bootloader (operating-system-bootloader os)))

(define enabled (with-seeedstudio-7inch-hdmi-display base
                  #:rotation 90
                  #:extra-config '("# Host settings" "display_rotate=3")))
(define boot (system-bootloader enabled))

(test-eq "changing Linux rotation reuses the configured firmware"
  boot (system-bootloader (with-seeedstudio-7inch-hdmi-display enabled #:rotation 180)))

(test-assert "the selected rotation also reaches the Linux command line"
  (member "video=HDMI-A-1:720x1280@60,rotate=90"
          (operating-system-user-kernel-arguments enabled)))

(test-assert "deployment replaces config.txt and installs the packaged timing fragment"
  (let* ((files (with-store store
                  (let ((drv (run-with-store store (lower-object (bootloader-package boot)))))
                    (build-derivations store (list drv))
                    (derivation->output-path drv))))
         (install (eval (gexp->approximate-sexp (bootloader-installer boot))
                        (current-module)))
         (root (mkdtemp "/tmp/spartan-display-XXXXXX"))
         (target "/boot/firmware")
         (fat (string-append root target))
         (config (string-append fat "/config.txt")))
    (dynamic-wind
      (const #t)
      (lambda ()
        (mkdir-p fat)
        (call-with-output-file config (lambda (port) (display "old config\n" port)))
        (install files target root)
        (let ((text (call-with-input-file config get-string-all))
              (fragment (string-append fat "/seeedstudio-7inch-hdmi.txt")))
          (and (string-prefix? base-config text)
               (string-suffix? "[all]\ninclude seeedstudio-7inch-hdmi.txt\n" text)
               (eq? 'regular (stat:type (lstat fragment)))
                (let* ((content (call-with-input-file fragment get-string-all))
                       (settings (string-split content #\newline)))
                  (and (member "disable_fw_kms_setup=1" settings)
                       (member "hdmi_timings=720 0 100 24 52 1280 0 10 4 4 0 0 0 60 0 70000000 0"
                               settings)
                       (not (member "display_rotate=1" settings))
                       (string-suffix? "# Host settings\ndisplay_rotate=3\n" content)))
               (file-exists? (string-append fat "/custom.txt"))
               (file-exists? (string-append fat "/u-boot.bin")))))
      (lambda () (delete-file-recursively root)))))

(test-end "displays")
(exit (zero? (test-runner-fail-count runner)))
