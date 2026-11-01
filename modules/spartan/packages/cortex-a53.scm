(define-module (spartan packages cortex-a53)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (guile-with-cortex-a53-fix))

(define (guile-with-cortex-a53-fix base)
  "Add the Cortex-A53 erratum 843419 linker workaround to BASE on AArch64.
This changes neither its compilation platform nor Guile's JIT settings."
  (package
    (inherit base)
    (location (package-location base))
    (arguments
     (if (target-aarch64?)
         (substitute-keyword-arguments (package-arguments base)
           ((#:configure-flags flags #~'())
            #~(begin
                (use-modules (srfi srfi-1))
                (let* ((flags #$flags)
                       (ldflags? (lambda (flag)
                                   (string-prefix? "LDFLAGS=" flag)))
                       (previous (find ldflags? flags)))
                  ;; The link-time workaround does not change code generated
                  ;; later by Guile's JIT.
                  (cons (string-append
                         (or previous "LDFLAGS=")
                         " -Wl,--fix-cortex-a53-843419")
                        (remove ldflags? flags))))))
         (package-arguments base)))))
