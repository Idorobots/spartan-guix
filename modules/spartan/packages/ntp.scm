(define-module (spartan packages ntp)
  #:use-module (gnu packages ntp)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (openntpd/cross-fixed))

(define openntpd/cross-fixed
  ;; Guix f519ddf searches target inputs for the shell used by update.sh.
  ;; This script runs during bootstrap, so it needs the build machine's shell.
  ;; Also exclude the raw OpenBSD headers from the cross compiler's include
  ;; path, as the upstream phase already does for native compilation.
  (package
    (inherit openntpd)
    (arguments
     (substitute-keyword-arguments (package-arguments openntpd)
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'fix-update-script
              (lambda* (#:key inputs native-inputs #:allow-other-keys)
                (substitute* "update.sh"
                  (("#!/bin/sh")
                   (string-append
                    "#!" (search-input-file (or native-inputs inputs) "/bin/sh")))
                  (("git") "true"))))
            (replace 'adjust-C_INCLUDE_PATH
              (lambda* (#:key inputs #:allow-other-keys)
                (let ((openbsd-include
                       (string-append (assoc-ref inputs "openbsd") "/include")))
                  (for-each
                   (lambda (variable)
                     (when (getenv variable)
                       (setenv variable
                               (string-join
                                (delete openbsd-include
                                        (string-split (getenv variable) #\:))
                                ":"))))
                   '("C_INCLUDE_PATH" "CROSS_C_INCLUDE_PATH")))))))))))
