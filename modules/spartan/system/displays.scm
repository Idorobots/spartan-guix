(define-module (spartan system displays)
  #:use-module (gnu packages linux)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (guix memoization)
  #:use-module (guix modules)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages displays)
  #:use-module (spartan packages mixed)
  #:use-module (srfi srfi-1)
  #:export (with-seeedstudio-7inch-hdmi-display))

(define display-kernel
  (memoize
   (lambda (kernel early-console?)
     (let ((previous (assq-ref (package-properties kernel) 'seeedstudio-7inch-hdmi)))
       (if previous
           (if (eq? early-console? (cdr previous))
               kernel
               (display-kernel (car previous) early-console?))
           (let* ((base kernel)
                  (configured
                   (customize-linux
                    #:linux base
                    #:configs (append '("CONFIG_FW_LOADER=y"
                                        "CONFIG_DRM_VC4=m"
                                        "CONFIG_DRM_LOAD_EDID_FIRMWARE=y"
                                        "CONFIG_HID_MULTITOUCH=m")
                                      (if early-console?
                                          '("CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y")
                                          '())))))
             (package
               (inherit configured)
               (properties (acons 'seeedstudio-7inch-hdmi (cons base early-console?)
                                  (package-properties configured)))
               (arguments
                (if (not early-console?)
                    (package-arguments configured)
                    (substitute-keyword-arguments (package-arguments configured)
                      ((#:imported-modules modules)
                       (append (source-module-closure
                                '((spartan build displays))
                                #:select? (lambda (module)
                                            (or (guix-module-name? module)
                                                (eq? (car module) 'spartan))))
                               modules))
                      ((#:phases phases)
                       #~(modify-phases #$phases
                           (add-after 'configure 'embed-display-edid
                             (lambda _
                               (use-modules (spartan build displays))
                               (configure-seeedstudio-display-firmware
                                #$(file-append seeedstudio-7inch-hdmi-config
                                               "/lib/firmware"))))))))))))))))

(define* (with-seeedstudio-7inch-hdmi-display os
                                            #:key
                                            (connector "HDMI-A-1")
                                            (rotation 270)
                                            (custom-kernel? #t)
                                            (early-console? #f))
  "Enable Seeed's 7-inch HDMI panel on CONNECTOR using its exact EDID timings.
CUSTOM-KERNEL? enables EDID firmware loading in OS's selected kernel. Set it to
#f only with a kernel that already supports EDID overrides and USB HID touch.
EARLY-CONSOLE? implies customization, embeds the EDID for use before firmware
activation, and enables console ROTATION. Otherwise VC4 must load after activation.
Graphical output rotation and touch calibration belong to the chosen session."
  (unless (and (string? connector) (not (string-null? connector))
               (every (lambda (c) (or (char-alphabetic? c) (char-numeric? c)
                                      (char=? c #\-)))
                      (string->list connector)))
    (error "invalid DRM connector name" connector))
  (unless (memv rotation '(0 90 180 270))
    (error "display rotation must be 0, 90, 180 or 270" rotation))
  (unless (and (boolean? custom-kernel?) (boolean? early-console?))
    (error "display kernel and early-console options must be booleans"))
  (let* ((video-prefix (string-append "video=" connector ":"))
         (edid-prefix (string-append connector ":"))
         (arguments (operating-system-user-kernel-arguments os))
         ;; Combine EDID overrides into one parameter; repeated module
         ;; parameters otherwise discard overrides for unrelated connectors.
         (edids
          (append-map
           (lambda (argument)
             (if (and (string? argument)
                      (string-prefix? "drm.edid_firmware=" argument))
                 (string-split (substring argument 18) #\,)
                 '()))
           arguments)))
    (operating-system
      (inherit os)
      (kernel (if (or custom-kernel? early-console?)
                  (map-compilation-package
                   (lambda (kernel) (display-kernel kernel early-console?))
                   (operating-system-kernel os))
                  (operating-system-kernel os)))
      (firmware (cons seeedstudio-7inch-hdmi-config
                      (delq seeedstudio-7inch-hdmi-config
                            (operating-system-firmware os))))
      (kernel-arguments
       (append
        (remove (lambda (argument)
                  (and (string? argument)
                       (or (string-prefix? video-prefix argument)
                           (string-prefix? "drm.edid_firmware=" argument))))
                arguments)
        (list
         (string-append
          "drm.edid_firmware="
          (string-join
           (append (remove (lambda (entry) (string-prefix? edid-prefix entry)) edids)
                   (list (string-append edid-prefix
                                        "edid/seeedstudio-7inch-720x1280.bin")))
           ","))
         (string-append video-prefix "720x1280e"
                        (if early-console?
                            (string-append ",rotate=" (number->string rotation))
                            ""))))))))
