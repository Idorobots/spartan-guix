(define-module (spartan packages rrdtool)
  #:use-module (gnu packages rrdtool)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages gtk)
  #:use-module (spartan packages perl)
  #:export (rrdtool/cross-fixed))

(define rrdtool/cross-fixed
  (let ((base (package-with-cross-fixed-pango rrdtool)))
    (package
      (inherit base)
      (inputs
       (if (%current-target-system)
           (modify-inputs (package-inputs base)
             (prepend perl/cross-fixed))
           (package-inputs base)))
      (arguments
       (if (%current-target-system)
           (substitute-keyword-arguments (package-arguments base)
             ((#:phases phases)
              #~(modify-phases #$phases
                  (add-before 'configure 'use-target-pkg-config
                    (lambda _
                      ;; RRDtool's custom dependency checks ignore PKG_CONFIG
                      ;; and search for an unprefixed executable instead.
                      (substitute* "configure"
                        (("pkg-config") #$(pkg-config-for-target)))))
                  (add-after 'configure 'configure-cross-perl
                    #$configure-cross-perl-phase)
                  (replace 'prepare-test-environment
                    (lambda* (#:key inputs native-inputs #:allow-other-keys)
                      (setenv "TZDIR"
                              (search-input-directory (or native-inputs inputs)
                                                      "share/zoneinfo")))))))
           (package-arguments base))))))
