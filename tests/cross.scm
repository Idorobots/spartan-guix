(use-modules (gnu packages admin)
             (gnu packages base)
             (gnu packages compression)
             (gnu packages dns)
             (gnu packages groff)
             (gnu packages gtk)
             (gnu packages linux)
             (gnu packages maths)
             (gnu packages ntp)
             (gnu packages perl)
             (gnu packages rrdtool)
             (gnu packages tls)
             (guix packages)
             (guix utils)
             (spartan packages admin)
             (spartan packages compression)
             (spartan packages cross)
             (spartan packages dns)
             (spartan packages groff)
             (spartan packages gtk)
             (spartan packages linux)
             (spartan packages maths)
             (spartan packages ntp)
             (spartan packages perl)
             (spartan packages rrdtool)
             (spartan packages tls)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "cross-selection")

(define variants
  (list (cons libcbor libcbor/cross-fixed)
        (cons isc-bind isc-bind/cross-fixed)
        (cons groff groff/cross-fixed)
        (cons groff-minimal groff-minimal/cross-fixed)
        (cons pango pango/cross-fixed)
        (cons alsa-lib alsa-lib/cross-fixed)
        (cons alsa-utils alsa-utils/cross-fixed)
        (cons lm-sensors lm-sensors/cross-fixed)
        (cons gnuplot gnuplot/cross-fixed)
        (cons ntp ntp/cross-fixed)
        (cons openntpd openntpd/cross-fixed)
        (cons perl perl/cross-fixed)
        (cons rrdtool rrdtool/cross-fixed)
        (cons perl-net-ssleay perl-net-ssleay/cross-fixed)
        (cons htop htop/cross-fixed)))

;; Upstream can construct fresh native inputs or origins on each access (for
;; example, gnuplot's texlive-local-tree and OpenNTPD's OpenBSD sources). Their
;; equivalence is checked by derivation tests; compare target/propagated packages.
(define (package-dependencies p)
  (map (lambda (field)
         (filter (lambda (input) (package? (cadr input))) (field p)))
       (list package-inputs package-propagated-inputs)))

(for-each
 (lambda (system)
   (parameterize ((%current-system system) (%current-target-system #f))
     (for-each
      (lambda (pair)
        (test-equal (format #f "~a ~a retains upstream native dependency objects"
                            (package-name (car pair)) system)
          (package-dependencies (car pair))
          (package-dependencies (cdr pair))))
      variants)))
 '("x86_64-linux" "aarch64-linux"))

;; Load and construct once, then alternate modes. This catches module-load-time
;; decisions and memoization that accidentally freezes the first build mode.
(define dependency (package (inherit hello) (outputs '("out" "tools"))))
(define fixed-dependency (package (inherit dependency) (name "hello-cross-fixed")))
(define consumer
  (package
    (inherit hello)
    (inputs `(("dep" ,dependency "tools") ("source" ,(package-source hello))))
    (propagated-inputs (list dependency))
    (native-inputs (list dependency))))
(define patched-consumer (package (inherit consumer) (version "patched")))
(define root
  (package
    (inherit hello)
    (inputs (list consumer))
    (propagated-inputs (list dependency))
    (native-inputs (list consumer))
    (replacement patched-consumer)))
(define rewrite
  (package-input-rewriting/cross `((,dependency . ,fixed-dependency))))
(define rewritten (rewrite root))

(test-assert "one memoized graph selects native, cross and native dependencies in turn"
  (every
   (lambda (target)
     (parameterize ((%current-target-system target))
       (let ((selected (lookup-package-input rewritten "hello"))
             (expected (if target fixed-dependency dependency)))
         (and (eq? rewritten (rewrite root))
              (eq? expected (lookup-package-input selected "dep"))
              (eq? expected (lookup-package-propagated-input selected "hello"))
              (eq? expected (lookup-package-propagated-input rewritten "hello"))
              (equal? (assoc "dep" (package-inputs selected))
                      (list "dep" expected "tools"))
              (equal? (assoc "source" (package-inputs selected))
                      (assoc "source" (package-inputs consumer)))
              (eq? dependency (lookup-package-native-input selected "hello"))
              (eq? consumer (lookup-package-native-input rewritten "hello"))))))
   '(#f "aarch64-linux-gnu" #f)))

(test-assert "native graft replacements stay upstream and cross grafts get dependency fixes"
  (and (eq? patched-consumer (package-replacement rewritten))
       (parameterize ((%current-target-system "aarch64-linux-gnu"))
         (eq? fixed-dependency
              (lookup-package-input (package-replacement rewritten) "dep")))
       (eq? patched-consumer (package-replacement rewritten))))

(define runner (test-runner-current))
(test-end "cross-selection")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
