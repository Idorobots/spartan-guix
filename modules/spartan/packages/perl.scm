(define-module (spartan packages perl)
  #:use-module (gnu packages perl)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (perl/cross-fixed
            configure-cross-perl-phase))

(define configure-cross-perl-phase
  ;; Build-only overlay for MakeMaker: target ABI/compiler/install paths,
  ;; but native XS modules and errno values for the executing interpreter.
  #~(lambda* (#:key inputs native-inputs #:allow-other-keys)
      (let* ((perl (assoc-ref inputs "perl"))
             (headers (find-files (string-append perl "/lib/perl5") "^perl\\.h$"))
             (archlib (dirname (dirname (car headers))))
             (config-dir (string-append (getcwd) "/cross-config"))
             (previous (getenv "PERL5LIB"))
             (native-perl (assoc-ref native-inputs "perl"))
             (errno (car (find-files (string-append native-perl "/lib/perl5")
                                     "^Errno\\.pm$"))))
        ;; Putting target archlib in @INC would load incompatible XS modules.
        (mkdir-p config-dir)
        (for-each (lambda (name)
                    (copy-file (string-append archlib "/" name)
                               (string-append config-dir "/" name)))
                  '("Config.pm" "Config_heavy.pl"))
        (copy-file errno (string-append config-dir "/Errno.pm"))
        (substitute* (string-append config-dir "/Errno.pm")
          (("die \"Errno architecture.*") "1;\n"))
        (setenv "PERL5LIB" (if previous
                              (string-append config-dir ":" previous)
                              config-dir)))))

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
