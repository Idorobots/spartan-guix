(define-module (spartan packages guile-config)
  #:use-module (gnu packages pkg-config)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages mixed)
  #:export (guile-with-native-config))

(define (guile-with-native-config base)
  "Make cross-built BASE's installed guile-config use destination pkg-config."
  (package
    (inherit base)
    (location (package-location base))
    (arguments
     (if (%current-target-system)
         (let ((sdk-pkg-config
                (package-with-compilation-system
                 ;; pkg-config is identifier syntax selecting the build-machine
                 ;; cross wrapper; use the primitive package instead.
                 %pkg-config
                 #:system (gnu-triplet->nix-system (%current-target-system)))))
           (substitute-keyword-arguments (package-arguments base)
             ((#:phases phases #~%standard-phases)
              #~(modify-phases #$phases
                  (add-after 'install 'use-native-sdk-pkg-config
                    (lambda* (#:key outputs #:allow-other-keys)
                      (substitute* (string-append (assoc-ref outputs "out")
                                                  "/bin/guile-config")
                        (("\\(define %pkg-config-program \"[^\"]*\"\\)")
                         (string-append
                          "(define %pkg-config-program \""
                          #$(file-append sdk-pkg-config "/bin/pkg-config")
                          "\")")))))))))
         (package-arguments base)))))
