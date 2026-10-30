(define-module (spartan packages tls)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages tls)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages cross)
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
                   #$configure-cross-perl-phase)
                 (add-before 'configure 'use-native-openssl-probe
                   (lambda* (#:key native-inputs #:allow-other-keys)
                    ;; Probe the build-machine OpenSSL executable, but keep
                    ;; OPENSSL_PREFIX pointing at target headers and libraries.
                    (setenv "BUILD_OPENSSL"
                            (search-input-file native-inputs "/bin/openssl"))
                    (substitute* "Makefile.PL"
                      (("my \\$exec   = find_openssl_exec\\(\\$prefix\\);")
                       "my $exec = $ENV{BUILD_OPENSSL};")))))))
         (package-arguments perl-net-ssleay)))))

(define package-with-cross-fixed-perl-net-ssleay
  (package-input-rewriting/cross
   `((,perl-net-ssleay . ,perl-net-ssleay/cross-fixed)
     (,perl . ,perl/cross-fixed))))
