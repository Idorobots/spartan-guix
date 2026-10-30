(define-module (spartan packages perl)
  #:use-module (gnu packages perl)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (perl/cross-fixed))

(define perl/cross-fixed
  (package
    (inherit perl)
    (arguments
     (if (%current-target-system)
         (substitute-keyword-arguments (package-arguments perl)
           ((#:phases phases)
            #~(modify-phases #$phases
                (add-after 'unpack-cross 'fix-errno-preprocessing
                  (lambda _
                    ;; Guix's cross patch replaces both cpp commands, losing
                    ;; the -P required for parsing expanded errno constants.
                    ;; Keep filename input: miniperl cannot execute the target
                    ;; shell to interpret a redirection on the build machine.
                    (substitute* "ext/Errno/Errno_pm.PL"
                      (("\\$Config\\{cc\\} -E errno\\.c")
                       "$cpp errno.c")
                      (("return \"\\$cppstdin [^\"]*\";")
                       "return \"$Config{cc} -E $Config{cppflags}\";"))))
                (add-after 'install 'install-target-headers
                  (lambda* (#:key outputs #:allow-other-keys)
                    ;; perl-cross leaves CORE without the generated headers
                    ;; needed to compile XS extensions for this exact Perl ABI.
                    (use-modules (ice-9 ftw))
                    (let* ((out (assoc-ref outputs "out"))
                           (config (find-files (string-append out "/lib/perl5")
                                               "^Config_heavy\\.pl$"))
                           (core (string-append (dirname (car config)) "/CORE")))
                      (for-each (lambda (file) (install-file file core))
                                (scandir "." (lambda (name)
                                               (string-suffix? ".h" name))))))))))
         (package-arguments perl)))))
