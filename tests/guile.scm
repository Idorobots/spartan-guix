(use-modules (gnu)
             (gnu image)
             (gnu packages guile)
             (gnu services shepherd)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix gexp)
             (guix packages)
             (guix utils)
             (spartan packages guile)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "guile-cortex-a53")

(define (configure-flags package system target)
  (parameterize ((%current-system system)
                 (%current-target-system target))
    (let ((flags (apply (lambda* (#:key configure-flags #:allow-other-keys)
                          configure-flags)
                        (package-arguments package))))
      (eval (gexp->approximate-sexp flags) (current-module)))))

(define variants
  (list (cons guile-3.0 guile-3.0/cortex-a53)
        (cons guile-3.0-latest guile-3.0-latest/cortex-a53)))

(test-assert "AArch64 native and cross links enable 843419 without disabling JIT"
  (every
   (lambda (pair)
     (every
      (lambda (system+target)
        (let ((flags (configure-flags (cdr pair) (car system+target)
                                      (cdr system+target))))
          (and (member "LDFLAGS= -Wl,--fix-cortex-a53-843419" flags)
               (member "--enable-mini-gmp" flags)
               (not (member "--disable-jit" flags)))))
      '(("x86_64-linux" . "aarch64-linux-gnu") ("aarch64-linux" . #f))))
   variants))

(test-assert "native x86 build tools retain upstream configure flags and versions"
  (every (lambda (pair)
           (and (string=? (package-version (car pair)) (package-version (cdr pair)))
                (equal? (configure-flags (car pair) "x86_64-linux" #f)
                        (configure-flags (cdr pair) "x86_64-linux" #f))))
         variants))

(test-assert "existing linker flags survive the workaround"
  (let* ((base (package
                (inherit guile-3.0-latest)
                (arguments
                 (substitute-keyword-arguments (package-arguments guile-3.0-latest)
                   ((#:configure-flags flags)
                    #~(cons "LDFLAGS=-Wl,--as-needed" #$flags))))))
         (fixed ((@@ (spartan packages guile) guile-with-cortex-a53-fix) base))
         (flags (configure-flags fixed "x86_64-linux" "aarch64-linux-gnu")))
    (and (member "LDFLAGS=-Wl,--as-needed -Wl,--fix-cortex-a53-843419" flags)
         (= 1 (count (lambda (flag) (string-prefix? "LDFLAGS=" flag)) flags)))))

(define converted
  (operating-system-for-image (os->image rpi3-barebones-os #:type rpi-image-type)))

(define (runtime-guiles package)
  (filter (lambda (p) (and (package? p) (string=? "guile" (package-name p))))
          (cons package (map cadr (package-transitive-target-inputs package)))))

(test-assert "profile, Guix and Shepherd select corrected Guile before and after conversion"
  (every
   (lambda (os)
     (let* ((services (operating-system-services os))
            (guix-config (service-value (fold-services services #:target-type guix-service-type)))
            (shepherd-config
             (service-value (fold-services services #:target-type shepherd-root-service-type)))
            (guiles
             (append-map runtime-guiles
                         (append (operating-system-packages os)
                                 (list (guix-configuration-guix guix-config)
                                       (shepherd-configuration-shepherd shepherd-config))))))
       (and (memq guile-3.0-latest/cortex-a53 guiles)
            (memq guile-3.0/cortex-a53 guiles)
            (not (memq guile-3.0 guiles))
            (not (memq guile-3.0-latest guiles)))))
   (list rpi3-barebones-os converted)))

(define runner (test-runner-current))
(test-end "guile-cortex-a53")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
