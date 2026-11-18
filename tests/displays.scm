(use-modules (gnu packages base)
             (gnu packages hardware)
             (gnu packages linux)
             (gnu services)
             (gnu system)
             (gnu system images raspberrypi)
             (guix build utils)
             (guix build-system)
             (guix derivations)
             (guix gexp)
             (guix monads)
             (guix packages)
             (guix store)
             (guix utils)
             (ice-9 popen)
             (ice-9 textual-ports)
             (rnrs bytevectors)
             ((rnrs io ports) #:select (get-bytevector-all))
             (spartan build displays)
             (spartan packages displays)
             (spartan packages mixed)
             (spartan system displays)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "displays")
(define runner (test-runner-current))

(define (realize package)
  (with-store store
    (let ((drv (package-derivation store package #:graft? #f)))
      (build-derivations store (list drv))
      (derivation->output-path drv))))

(define config (realize seeedstudio-7inch-hdmi-config))
(define edid-file
  (string-append config "/lib/firmware/edid/seeedstudio-7inch-720x1280.bin"))
(define edid (call-with-input-file edid-file get-bytevector-all))
(define (byte offset) (bytevector-u8-ref edid offset))

(test-assert "built package contains one valid base EDID with a preferred timing"
  (and (= 128 (bytevector-length edid))
       (zero? (modulo (apply + (bytevector->u8-list edid)) 256))
       (equal? '(0 255 255 255 255 255 255 0)
               (take (bytevector->u8-list edid) 8))
       (= 0 (byte 126))
       (not (zero? (logand (byte 24) 2)))))

;; Decode independently of the writer's byte layout construction.
(test-equal "preferred DTD reproduces the vendor clock, active area and blanking"
  '(70000000 720 176 1280 18 100 24 10 4 24)
  (list (* 10000 (bytevector-u16-ref edid 54 (endianness little)))
        (+ (byte 56) (* 256 (ash (byte 58) -4)))
        (+ (byte 57) (* 256 (logand (byte 58) 15)))
        (+ (byte 59) (* 256 (ash (byte 61) -4)))
        (+ (byte 60) (* 256 (logand (byte 61) 15)))
        (+ (byte 62) (* 256 (ash (byte 65) -6)))
        (+ (byte 63) (* 256 (logand (ash (byte 65) -4) 3)))
        (+ (ash (byte 64) -4) (* 16 (logand (ash (byte 65) -2) 3)))
        (+ (logand (byte 64) 15) (* 16 (logand (byte 65) 3)))
        (byte 71)))

(test-assert "independent decoder accepts the installed EDID"
  (let* ((port (open-pipe* OPEN_READ
                           (string-append (realize edid-decode) "/bin/edid-decode")
                           "--check" edid-file))
         (text (get-string-all port))
         (status (close-pipe port)))
    (unless (zero? status) (display text))
    (and (zero? status) (string-contains text "EDID conformity: PASS"))))

(define extra-argument #~"loglevel=4")
(define base
  (operating-system
    (inherit rpi3-barebones-os)
    (kernel-arguments
     (append (operating-system-user-kernel-arguments rpi3-barebones-os)
             (list extra-argument)
             '("video=HDMI-A-1:640x480" "video=HDMI-A-2:1920x1080"
               "drm.edid_firmware=HDMI-A-2:edid/other.bin,HDMI-A-1:edid/old.bin")))))
(define enabled (with-seeedstudio-7inch-hdmi-display base))
(define arguments (operating-system-user-kernel-arguments enabled))
(define early
  (with-seeedstudio-7inch-hdmi-display base #:early-console? #t))

(test-assert "default setup customizes the kernel and enables EDID without console rotation"
  (and (not (eq? (operating-system-kernel base) (operating-system-kernel enabled)))
       (member "video=HDMI-A-1:720x1280e" arguments)
       (not (any (lambda (a) (and (string? a) (string-contains a ",rotate=")))
                 arguments))
       (memq seeedstudio-7inch-hdmi-config (operating-system-firmware enabled))))

(test-assert "an EDID-capable kernel can be retained with the same firmware override"
  (let ((stock (with-seeedstudio-7inch-hdmi-display enabled #:custom-kernel? #f)))
    (and (eq? (operating-system-kernel enabled) (operating-system-kernel stock))
         (equal? arguments (operating-system-user-kernel-arguments stock)))))

(test-assert "early-console setup implies customization and requests rotation"
  (let ((os (with-seeedstudio-7inch-hdmi-display
             base #:custom-kernel? #f #:early-console? #t)))
    (and (eq? (operating-system-kernel early) (operating-system-kernel os))
         (member "video=HDMI-A-1:720x1280e,rotate=270"
                 (operating-system-user-kernel-arguments os)))))

(test-assert "opt-in preserves the base system, other displays and firmware"
  (and (eq? (operating-system-bootloader base)
            (operating-system-bootloader enabled))
       (equal? (operating-system-user-services base)
               (operating-system-user-services enabled))
       (every (lambda (p) (memq p (operating-system-firmware enabled)))
              (operating-system-firmware base))
       (every (lambda (a) (member a arguments))
              (operating-system-user-kernel-arguments rpi3-barebones-os))
       (memq extra-argument arguments)
       (member "video=HDMI-A-2:1920x1080" arguments)
       (member "video=HDMI-A-1:720x1280e" arguments)
       (not (member "video=HDMI-A-1:640x480" arguments))
       (member (string-append "drm.edid_firmware=HDMI-A-2:edid/other.bin,"
                              "HDMI-A-1:edid/seeedstudio-7inch-720x1280.bin")
               arguments)
       (not (memq seeedstudio-7inch-hdmi-config
                  (operating-system-firmware base)))))

(test-assert "reapplying the helper does not stack kernel transformations"
  (every
   (lambda (os early-console?)
     (let ((again (with-seeedstudio-7inch-hdmi-display
                   os #:early-console? early-console?)))
       (and (eq? (operating-system-kernel os) (operating-system-kernel again))
            (equal? (operating-system-user-kernel-arguments os)
                    (operating-system-user-kernel-arguments again))
            (= 1 (count (lambda (p) (eq? p seeedstudio-7inch-hdmi-config))
                        (operating-system-firmware again))))))
   (list enabled early) '(#f #t)))

(test-assert "switching early-console setup reuses the original kernel recipe"
  (let* ((upgraded (with-seeedstudio-7inch-hdmi-display enabled #:early-console? #t))
         (reverted (with-seeedstudio-7inch-hdmi-display upgraded)))
    (and (eq? (operating-system-kernel early) (operating-system-kernel upgraded))
         (eq? (operating-system-kernel enabled) (operating-system-kernel reverted))
         (equal? arguments (operating-system-user-kernel-arguments reverted)))))

(test-assert "connector and orientation are configurable"
  (member "video=HDMI-A-2:720x1280e,rotate=0"
          (operating-system-user-kernel-arguments
           (with-seeedstudio-7inch-hdmi-display
             rpi3-barebones-os #:connector "HDMI-A-2" #:rotation 0
             #:early-console? #t))))
(test-error "unsupported rotation fails during configuration" #t
  (with-seeedstudio-7inch-hdmi-display base #:rotation 45))
(test-error "malformed connector fails during configuration" #t
  (with-seeedstudio-7inch-hdmi-display base #:connector "HDMI-A-1:bad"))
(test-error "invalid early-console option fails during configuration" #t
  (with-seeedstudio-7inch-hdmi-display base #:early-console? 'yes))
(test-error "invalid kernel customization option fails during configuration" #t
  (with-seeedstudio-7inch-hdmi-display base #:custom-kernel? 'yes))

(define (expand value)
  (cond ((gexp? value) (expand (gexp->approximate-sexp value)))
        ((pair? value) (cons (expand (car value)) (expand (cdr value))))
        (else value)))

(test-assert "adapted kernel lowers the customized recipe with its original routing"
  (parameterize (((@@ (spartan packages mixed) %native-outputs-available?)
                  (const #f)))
    (let* ((kernel (operating-system-kernel early))
           (bag (package->bag kernel "aarch64-linux" #f #:graft? #f))
           (text (object->string (expand (bag-arguments bag)))))
      (and (eq? (package-source kernel)
                (package-source (operating-system-kernel base)))
           (string=? "mixed-compilation"
                     (symbol->string (build-system-name (package-build-system kernel))))
           (string=? "x86_64-linux" (bag-system bag))
           (string=? "aarch64-linux-gnu" (bag-target bag))
           (every (lambda (setting) (string-contains text setting))
                  '("CONFIG_FW_LOADER=y" "CONFIG_DRM_VC4=m"
                    "CONFIG_DRM_LOAD_EDID_FIRMWARE=y"
                    "CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y" "CONFIG_HID_MULTITOUCH=m"
                    "configure-seeedstudio-display-firmware"))
           (member '(spartan build displays)
                    (cadr (memq #:imported-modules (bag-arguments bag))))))))

(test-assert "default kernel recipe enables EDID without embedding or adding console rotation"
  (parameterize (((@@ (spartan packages mixed) %native-outputs-available?)
                  (const #f)))
    (let* ((kernel (operating-system-kernel enabled))
           (bag (package->bag kernel "aarch64-linux" #f #:graft? #f))
           (text (object->string (expand (bag-arguments bag)))))
      (and (eq? (package-source kernel)
                (package-source (operating-system-kernel base)))
           (string=? "x86_64-linux" (bag-system bag))
           (string=? "aarch64-linux-gnu" (bag-target bag))
           (string-contains text "CONFIG_DRM_LOAD_EDID_FIRMWARE=y")
           (not (string-contains text "CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y"))
           (not (string-contains text "configure-seeedstudio-display-firmware"))))))

(test-assert "Guix firmware activation exposes the installed EDID through its search path"
  (let* ((activation
          (fold-services
           (list (service firmware-service-type (list seeedstudio-7inch-hdmi-config))
                 (service activation-service-type)
                 (service boot-service-type)
                 (service system-service-type '()))
           #:target-type activation-service-type))
         (check
          (computed-file
           "display-firmware-activation-check"
           #~(begin
               (define (activate-firmware directory)
                 (copy-file
                  (string-append directory "/edid/seeedstudio-7inch-720x1280.bin")
                  #$output))
               #$@(service-value activation))))
         (file (with-store store
                 (let ((drv (run-with-store store (lower-object check))))
                   (build-derivations store (list drv))
                   (derivation->output-path drv)))))
    (and (not (member "vc4" (operating-system-initrd-modules enabled)))
         (equal? edid (call-with-input-file file get-bytevector-all)))))

(test-assert "mapping a recipe retains native cache selection and metadata"
  (let* ((toy (package (inherit hello) (name "display-routing-test")))
         (transform (lambda (p) (package (inherit p) (version "2"))))
         (native-checked? #f))
    (parameterize (((@@ (spartan packages mixed) %native-outputs-available?)
                    (lambda (recipe candidate system)
                      (set! native-checked? (string=? "2" (package-version recipe)))
                      #t)))
      (let* ((mapped (map-compilation-package
                      transform (package-with-compilation-system
                                 toy #:system "x86_64-linux")))
             (bag (package->bag mapped "aarch64-linux" #f #:graft? #f)))
        (and native-checked? (string=? "aarch64-linux" (bag-system bag))
             (not (bag-target bag))
             (equal? (package-properties toy) (package-properties mapped)))))))

;; Exercise the actual embedding step with another existing firmware blob.
;; The tiny Makefile stands in for olddefconfig; no kernel is compiled here.
(define temporary (mkdtemp "/tmp/spartan-display-XXXXXX"))
(define make-bin (string-append (realize gnu-make) "/bin"))
(test-assert "embedding makes the EDID early-loadable and retains existing built-in firmware"
  (dynamic-wind
    (const #t)
    (lambda ()
      (with-directory-excursion temporary
        (mkdir "old-firmware")
        (call-with-output-file "old-firmware/other.bin"
          (lambda (p) (display "existing firmware" p)))
        (call-with-output-file ".config"
          (lambda (p)
            (display "CONFIG_EXTRA_FIRMWARE=\"other.bin\"\n" p)
            (display "CONFIG_EXTRA_FIRMWARE_DIR=\"old-firmware\"\n" p)
            (display "CONFIG_UNRELATED=y\n" p)))
        (call-with-output-file "Makefile"
          (lambda (p) (display "olddefconfig:\n\t@test -s spartan-display-firmware/edid/seeedstudio-7inch-720x1280.bin\n" p)))
        (with-environment-variables
            (list (list "PATH" (string-append make-bin ":" (getenv "PATH")))
                  '("LC_ALL" "C"))
          (configure-seeedstudio-display-firmware
           (string-append config "/lib/firmware")))
        (let ((text (call-with-input-file ".config" get-string-all)))
          (and (string-contains text "CONFIG_UNRELATED=y")
               (string-contains text "other.bin edid/seeedstudio-7inch-720x1280.bin")
               (string=? "existing firmware"
                          (call-with-input-file
                              "spartan-display-firmware/other.bin" get-string-all))
               (equal? edid (call-with-input-file
                               "spartan-display-firmware/edid/seeedstudio-7inch-720x1280.bin"
                             get-bytevector-all))))))
    (lambda () (delete-file-recursively temporary))))

(test-end "displays")
(exit (zero? (test-runner-fail-count runner)))
