(use-modules (gnu packages ntp)
             (gnu packages perl)
             (gnu packages tls)
             (gnu services networking)
             (guix build-system)
             (guix derivations)
             (guix packages)
             (guix store)
             (spartan packages ntp)
             (spartan packages perl)
             (spartan packages tls)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "ntp-cross")

(test-assert "native x86 and AArch64 recipes remain identical to upstream"
  (with-store store
    (every
     (lambda (pair)
       (every (lambda (system)
                (string=?
                 (derivation-file-name
                  (package-derivation store (car pair) system #:graft? #f))
                 (derivation-file-name
                  (package-derivation store (cdr pair) system #:graft? #f))))
              '("x86_64-linux" "aarch64-linux")))
     (list (cons perl perl/cross-fixed)
           (cons perl-net-ssleay perl-net-ssleay/cross-fixed)
           (cons ntp ntp/cross-fixed)))))

(test-assert "XS builds have native OpenSSL for probes and target Perl for ABI"
  (let ((bag (package->bag perl-net-ssleay/cross-fixed
                           "x86_64-linux" "aarch64-linux-gnu")))
    (and (equal? (assoc-ref (bag-build-inputs bag) "openssl") (list openssl))
         (equal? (assoc-ref (bag-host-inputs bag) "openssl") (list openssl))
         (equal? (assoc-ref (bag-host-inputs bag) "perl")
                 (list perl/cross-fixed)))))

(test-assert "reference NTP retains all HTTPS helper inputs and rewrites every SSL path"
  (let* ((http (lookup-package-input ntp/cross-fixed "perl-http-tiny"))
         (ssl (lookup-package-input ntp/cross-fixed "perl-io-socket-ssl")))
    (and (eq? perl/cross-fixed (lookup-package-input ntp/cross-fixed "perl"))
         (eq? perl-net-ssleay/cross-fixed
              (lookup-package-input ntp/cross-fixed "perl-net-ssleay"))
         (eq? perl-net-ssleay/cross-fixed
              (lookup-package-input http "perl-net-ssleay"))
         (eq? perl-net-ssleay/cross-fixed
              (lookup-package-propagated-input ssl "perl-net-ssleay")))))

(test-assert "reference NTP service retains large initial clock adjustments"
  (ntp-allow-large-adjustment? (ntp-configuration (ntp ntp/cross-fixed))))

(define runner (test-runner-current))
(test-end "ntp-cross")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
