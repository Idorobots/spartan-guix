(define-module (spartan packages displays)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix modules)
  #:use-module (guix packages))

(define-public seeedstudio-7inch-hdmi-config
  (package
    (name "seeedstudio-7inch-hdmi-config")
    (version "1.0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules (source-module-closure
                 '((spartan build displays))
                 #:select? (lambda (module)
                             (or (guix-module-name? module)
                                 (eq? (car module) 'spartan))))
      #:builder
      #~(begin
          (use-modules (guix build utils) (spartan build displays))
          (let ((directory (string-append #$output "/lib/firmware/edid")))
            (mkdir-p directory)
            (write-seeedstudio-7inch-edid
             (string-append directory "/seeedstudio-7inch-720x1280.bin"))))))
    (home-page
     "https://www.seeedstudio.com/7-inch-720x1280-HDMI-IPS-LCD-Display-p-2861.html")
    (synopsis "Native HDMI timings for the Seeed Studio 7-inch IPS display")
    (description
     "This package provides a generated EDID for Seeed Studio's 7-inch
720x1280 HDMI IPS panel, using its documented 70 MHz timings.  The data is
independent of Xorg or Wayland.  The with-seeedstudio-7inch-hdmi-display system
helper configures a variant of the selected kernel with EDID firmware loading
and USB HID touch support.  Embedding the EDID for early availability and
rotating the text console are optional.  Graphical output and touch transforms
belong to the chosen application or compositor.")
    (license license:gpl3+)))
