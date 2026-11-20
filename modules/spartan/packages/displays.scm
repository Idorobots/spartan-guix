(define-module (spartan packages displays)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (srfi srfi-1)
  #:export (make-seeedstudio-7inch-hdmi-config))

(define %seeedstudio-7inch-config
  '("# Seeed Studio 7-inch HDMI panel."
    "disable_fw_kms_setup=1"
    "hdmi_pixel_freq_limit=400000000"
    "hdmi_force_hotplug=1"
    "hdmi_ignore_edid=0xa5000080"
    "hdmi_group=2"
    "hdmi_mode=87"
    "hdmi_timings=720 0 100 24 52 1280 0 10 4 4 0 0 0 60 0 70000000 0"
    "config_hdmi_boost=4"
    "disable_overscan=1"
    "max_framebuffers=2"
    "max_framebuffer_width=1280"
    "max_framebuffer_height=1280"
    "framebuffer_width=1280"
    "framebuffer_height=720"))

(define* (make-seeedstudio-7inch-hdmi-config #:key (extra-config '()))
  "Return the display package with EXTRA-CONFIG strings appended in order."
  (unless (and (list? extra-config) (every string? extra-config))
    (error "Seeed display extra-config must be a list of strings" extra-config))
  (package
    (name "seeedstudio-7inch-hdmi-config")
    (version "1.0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((boot (string-append #$output "/share/raspberrypi")))
            (mkdir-p boot)
            (call-with-output-file (string-append boot "/seeedstudio-7inch-hdmi.txt")
              (lambda (port)
                (display #$(string-join (append %seeedstudio-7inch-config extra-config)
                                        "\n" 'suffix)
                         port)))))))
    (home-page
     "https://www.seeedstudio.com/7-inch-720x1280-HDMI-IPS-LCD-Display-p-2861.html")
    (synopsis "Raspberry Pi firmware timings for the Seeed Studio 7-inch display")
    (description "This package provides a Raspberry Pi firmware configuration
fragment for Seeed Studio's 7-inch 720x1280 HDMI IPS panel, using its documented
70 MHz timings.")
    (license license:gpl3+)))

(define-public seeedstudio-7inch-hdmi-config
  (make-seeedstudio-7inch-hdmi-config))
