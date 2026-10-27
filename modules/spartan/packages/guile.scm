(define-module (spartan packages guile)
  #:use-module (gnu packages guile)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (guile-3.0/cortex-a53
            guile-3.0-latest/cortex-a53
            package-with-cortex-a53-guile))

(define (guile-with-cortex-a53-fix base)
  ;; Erratum 843419 can corrupt a load in compiled C code in libguile when
  ;; an ADRP sequence straddles a 4 KiB boundary.  This is a link-time fix;
  ;; it does not change code generated later by Guile's JIT.
  (package
    (inherit base)
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
                  (cons (string-append
                         (or previous "LDFLAGS=")
                         " -Wl,--fix-cortex-a53-843419")
                        (remove ldflags? flags))))))
         (package-arguments base)))))

;; Preserve the upstream versions: the default service interpreter and the
;; interactive interpreter need not be the same Guile release.
(define guile-3.0/cortex-a53
  (guile-with-cortex-a53-fix guile-3.0))

(define guile-3.0-latest/cortex-a53
  (guile-with-cortex-a53-fix guile-3.0-latest))

;; Rewrite explicit dependencies, including Guile extensions, without rewriting
;; the entire bootstrap toolchain through implicit build-system inputs.  Native
;; build tools retain upstream arguments because the flag is AArch64-only.
(define package-with-cortex-a53-guile
  (package-input-rewriting
   `((,guile-3.0 . ,guile-3.0/cortex-a53)
     (,guile-3.0-latest . ,guile-3.0-latest/cortex-a53))
   #:deep? #f))
