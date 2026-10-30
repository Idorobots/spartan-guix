(define-module (spartan packages ntp)
  #:use-module (gnu packages ntp)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages tls)
  #:export (ntp/cross-fixed
            openntpd/cross-fixed))

(define ntp/cross-fixed
  ;; Preserve update-leap and its HTTPS dependencies, including indirect
  ;; references through HTTP::Tiny and IO::Socket::SSL.
  (let ((rewritten (package-with-cross-fixed-perl-net-ssleay ntp)))
    (package
      (inherit rewritten)
      (arguments
       (if (%current-target-system)
           (substitute-keyword-arguments (package-arguments rewritten)
             ((#:phases phases)
              #~(modify-phases #$phases
                  (add-before 'configure 'set-target-perl
                    (lambda* (#:key inputs #:allow-other-keys)
                      ;; Configure need not execute Perl to embed its path.
                      (setenv "PATH_PERL"
                              (search-input-file inputs "/bin/perl"))))
                  (replace 'adjust-scripts
                    (lambda* (#:key inputs outputs #:allow-other-keys)
                      (let* ((out (assoc-ref outputs "out"))
                             (guile (search-input-file inputs "/bin/guile"))
                             ;; Cross builds do not populate PERL5LIB from
                             ;; target inputs automatically.
                             (paths (filter file-exists?
                                            (map (lambda (input)
                                                   (string-append (cdr input)
                                                                  "/lib/perl5/site_perl"))
                                                 inputs))))
                        (substitute* (string-append out "/bin/calc_tickadj")
                          (("/etc/ntp/drift") "/var/run/ntpd/ntp.drift"))
                        (wrap-script (string-append out "/bin/update-leap")
                          #:guile guile
                          `("PERL5LIB" ":" prefix ,paths))))))))
           (package-arguments rewritten))))))

(define openntpd/cross-fixed
  ;; Guix f519ddf searches target inputs for the shell used by update.sh.
  ;; This script runs during bootstrap, so it needs the build machine's shell.
  ;; Also exclude the raw OpenBSD headers from the cross compiler's include
  ;; path, as the upstream phase already does for native compilation.
  (package
    (inherit openntpd)
    (arguments
     (if (%current-target-system)
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
                       '("C_INCLUDE_PATH" "CROSS_C_INCLUDE_PATH"))))))))
         (package-arguments openntpd)))))
