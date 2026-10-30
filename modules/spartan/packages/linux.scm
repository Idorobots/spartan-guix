(define-module (spartan packages linux)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages cross)
  #:use-module (spartan packages maths)
  #:use-module (spartan packages rrdtool)
  #:export (alsa-lib/cross-fixed
            alsa-utils/cross-fixed
            package-with-cross-fixed-alsa
            lm-sensors/cross-fixed
            package-with-cross-fixed-lm-sensors))

(define lm-sensors/cross-fixed
  (package
    (inherit lm-sensors)
    (inputs
     (if (%current-target-system)
         (modify-inputs (package-inputs lm-sensors)
           (replace "gnuplot" gnuplot/cross-fixed)
           (replace "rrdtool" rrdtool/cross-fixed)
           ;; Script paths must name target tools, not the implicit native
           ;; build inputs that happen to be present in a native build.
           (prepend coreutils grep sed))
         (package-inputs lm-sensors)))
    (arguments
     (if (%current-target-system)
         (substitute-keyword-arguments (package-arguments lm-sensors)
           ((#:make-flags flags #~'())
            #~(cons* #$(string-append "CC=" (cc-for-target))
                     #$(string-append "AR=" (ar-for-target))
                     #$flags)))
         (package-arguments lm-sensors)))))

(define package-with-cross-fixed-lm-sensors
  (package-input-rewriting/cross
   `((,lm-sensors . ,lm-sensors/cross-fixed))))

(define alsa-lib/cross-fixed
  ;; The pinned ALSA recipe bootstraps a Git checkout, but puts its build
  ;; tools in inputs.  They must run on the build machine, not the target.
  (package
    (inherit alsa-lib)
    (native-inputs
     (if (%current-target-system)
         (append (map (lambda (name)
                        (list name (lookup-package-input alsa-lib name)))
                      '("autoconf" "automake" "libtool"))
                 (package-native-inputs alsa-lib))
         (package-native-inputs alsa-lib)))
    (inputs
     (if (%current-target-system)
         (modify-inputs (package-inputs alsa-lib)
           (delete "autoconf" "automake" "libtool"))
         (package-inputs alsa-lib)))))

(define alsa-utils/cross-fixed
  (package
    (inherit alsa-utils)
    (inputs
     (if (%current-target-system)
         (modify-inputs (package-inputs alsa-utils)
           (replace "alsa-lib" alsa-lib/cross-fixed)
           ;; The udev rule invokes cat on the target, whereas implicit
           ;; coreutils is available only on the build machine.
           (prepend coreutils-minimal))
         (package-inputs alsa-utils)))))

(define package-with-cross-fixed-alsa
  (package-input-rewriting/cross
   `((,alsa-lib . ,alsa-lib/cross-fixed)
     (,alsa-utils . ,alsa-utils/cross-fixed))))
