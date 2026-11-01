(define-module (spartan packages guile-snarf)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (guile-with-native-snarf))

(define (guile-with-native-snarf base)
  "Make cross-built BASE's installed guile-snarf use the consumer's compiler.
Explicit CPP is retained; otherwise CC or native gcc supplies the preprocessor."
  (package
    (inherit base)
    (location (package-location base))
    (arguments
     (if (%current-target-system)
         (substitute-keyword-arguments (package-arguments base)
           ((#:phases phases #~%standard-phases)
            #~(modify-phases #$phases
                (add-after 'install 'use-native-sdk-preprocessor
                  (lambda* (#:key outputs #:allow-other-keys)
                    ;; Keep the script's CPP override and replace only its
                    ;; configure-time cross-compiler fallback.
                    (substitute* (string-append (assoc-ref outputs "out")
                                                "/bin/guile-snarf")
                      (("then cpp=\"[^\"]*\"")
                       "then cpp=\"${CC:-gcc} -E\"")))))))
         (package-arguments base)))))
