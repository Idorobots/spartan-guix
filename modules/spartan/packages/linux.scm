(define-module (spartan packages linux)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (alsa-lib/cross-fixed
            alsa-utils/cross-fixed
            package-with-cross-fixed-alsa))

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
     (let ((inputs (modify-inputs (package-inputs alsa-utils)
                     (replace "alsa-lib" alsa-lib/cross-fixed))))
       (if (%current-target-system)
           (modify-inputs inputs
             ;; The udev rule invokes cat on the target, whereas implicit
             ;; coreutils is available only on the build machine.
             (prepend coreutils-minimal))
           inputs)))))

(define package-with-cross-fixed-alsa
  (package-input-rewriting
   `((,alsa-lib . ,alsa-lib/cross-fixed)
     (,alsa-utils . ,alsa-utils/cross-fixed))
   #:deep? #f))
