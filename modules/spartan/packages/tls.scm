(define-module (spartan packages tls)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages tls)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages perl)
  #:export (perl-net-ssleay/cross-fixed
            package-with-cross-fixed-perl-net-ssleay))

(define perl-net-ssleay/cross-fixed
  (package
    (inherit perl-net-ssleay)
    (native-inputs
     (if (%current-target-system)
         (modify-inputs (package-native-inputs perl-net-ssleay)
           (prepend openssl))
         (package-native-inputs perl-net-ssleay)))
    (arguments
     (if (%current-target-system)
         (substitute-keyword-arguments
              (append (list #:perl perl/cross-fixed)
                     (package-arguments perl-net-ssleay))
           ((#:phases phases)
            #~(modify-phases #$phases
                (add-before 'configure 'configure-cross-perl
                  (lambda* (#:key inputs native-inputs #:allow-other-keys)
                    ;; MakeMaker runs on the build machine, but must generate
                    ;; the target Perl ABI, compiler and installation paths.
                    (let* ((perl (assoc-ref inputs "perl"))
                           (headers (find-files (string-append perl "/lib/perl5")
                                                "^perl\\.h$"))
                           (archlib (dirname (dirname (car headers))))
                           (config-dir (string-append (getcwd) "/cross-config"))
                           (previous (getenv "PERL5LIB")))
                      ;; Do not put the entire target archlib in @INC: its
                      ;; XS modules cannot be loaded by the native Perl.
                      (mkdir-p config-dir)
                      (for-each (lambda (name)
                                  (copy-file (string-append archlib "/" name)
                                             (string-append config-dir "/" name)))
                                '("Config.pm" "Config_heavy.pl"))
                      ;; Native Perl's generated Errno refuses a target Config.
                      ;; Its constants are only used by build-time Perl tools.
                      (let* ((native-perl (assoc-ref native-inputs "perl"))
                             (errno (car (find-files
                                          (string-append native-perl "/lib/perl5")
                                          "^Errno\\.pm$"))))
                        (copy-file errno (string-append config-dir "/Errno.pm"))
                        (substitute* (string-append config-dir "/Errno.pm")
                          (("die \"Errno architecture.*") "1;\n")))
                      (setenv "PERL5LIB"
                              (if previous
                                  (string-append config-dir ":" previous)
                                  config-dir)))
                    ;; Probe the build-machine OpenSSL executable, but keep
                    ;; OPENSSL_PREFIX pointing at target headers and libraries.
                    (setenv "BUILD_OPENSSL"
                            (search-input-file native-inputs "/bin/openssl"))
                    (substitute* "Makefile.PL"
                      (("my \\$exec   = find_openssl_exec\\(\\$prefix\\);")
                       "my $exec = $ENV{BUILD_OPENSSL};")))))))
         (package-arguments perl-net-ssleay)))))

(define package-with-cross-fixed-perl-net-ssleay
  (package-input-rewriting
   `((,perl-net-ssleay . ,perl-net-ssleay/cross-fixed)
     (,perl . ,perl/cross-fixed))
   #:deep? #f))
