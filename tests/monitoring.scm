(use-modules (gnu packages admin)
             (gnu packages gtk)
             (gnu packages linux)
             (gnu packages maths)
             (gnu packages rrdtool)
             (guix build-system)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (guix utils)
             (spartan packages admin)
             (spartan packages gtk)
             (spartan packages linux)
             (spartan packages maths)
             (spartan packages perl)
             (spartan packages rrdtool)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "monitoring-cross")

(define (flags package keyword)
  (parameterize ((%current-system "x86_64-linux")
                 (%current-target-system "aarch64-linux-gnu"))
    (eval (gexp->approximate-sexp
           (cadr (memq keyword (package-arguments package))))
          (current-module))))

(test-assert "native monitoring packages, including htop, keep upstream derivations"
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
     (list (cons pango pango/cross-fixed)
           (cons gnuplot gnuplot/cross-fixed)
           (cons rrdtool rrdtool/cross-fixed)
           (cons lm-sensors lm-sensors/cross-fixed)
           (cons htop htop/cross-fixed)))))

(test-assert "cross Pango omits introspection only, retaining rendering dependencies"
  (let ((flags (flags pango/cross-fixed #:configure-flags))
        (bag (package->bag pango/cross-fixed "x86_64-linux" "aarch64-linux-gnu")))
    (and (= 1 (count (lambda (flag) (string-prefix? "-Dintrospection=" flag)) flags))
         (member "-Dintrospection=disabled" flags)
         (not (assoc-ref (bag-build-inputs bag) "gobject-introspection"))
         (every (lambda (name) (assoc-ref (bag-host-inputs bag) name))
                '("cairo" "fontconfig-minimal" "freetype" "harfbuzz" "libxft")))))

(test-assert "gnuplot has native Lua for help and target Lua for runtime linking"
  (let ((bag (package->bag gnuplot/cross-fixed "x86_64-linux" "aarch64-linux-gnu")))
    (and (equal? (assoc-ref (bag-build-inputs bag) "lua")
                 (assoc-ref (bag-host-inputs bag) "lua"))
         (assoc-ref (bag-build-inputs bag) "lua")
         (parameterize ((%current-target-system "aarch64-linux-gnu"))
           (eq? pango/cross-fixed (lookup-package-input gnuplot/cross-fixed "pango"))))))

(test-assert "RRDtool retains native Perl and adds target Perl for XS compilation"
  (let ((bag (package->bag rrdtool/cross-fixed "x86_64-linux" "aarch64-linux-gnu")))
    (and (assoc-ref (bag-build-inputs bag) "perl")
         (equal? (assoc-ref (bag-host-inputs bag) "perl") (list perl/cross-fixed)))))

(test-assert "sensors retains both outputs and target script tools"
  (let ((bag (package->bag lm-sensors/cross-fixed "x86_64-linux" "aarch64-linux-gnu")))
    (and (equal? '("lib" "out") (package-outputs lm-sensors/cross-fixed))
         (every (lambda (name) (assoc-ref (bag-host-inputs bag) name))
                '("coreutils" "grep" "sed")))))

(test-assert "htop/cross-fixed selects both corrected plotting branches through sensors"
  (parameterize ((%current-target-system "aarch64-linux-gnu"))
    (let ((sensors (lookup-package-input htop/cross-fixed "lm-sensors")))
      (and (eq? sensors lm-sensors/cross-fixed)
           (eq? gnuplot/cross-fixed (lookup-package-input sensors "gnuplot"))
           (eq? rrdtool/cross-fixed (lookup-package-input sensors "rrdtool"))
           (eq? pango/cross-fixed (lookup-package-input rrdtool/cross-fixed "pango"))))))

(define runner (test-runner-current))
(test-end "monitoring-cross")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
