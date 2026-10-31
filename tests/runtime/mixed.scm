;; Optional integration check: requires a daemon able to execute AArch64 code
;; (natively, through offloading, or with transparent binfmt/QEMU execution).
;; Run from the channel root: guix repl -L modules tests/runtime/mixed.scm
(use-modules (gnu packages guile)
             (guix derivations)
             (guix gexp)
             (guix monads)
             (guix store)
             (ice-9 textual-ports)
             (spartan packages guile))

(define zlib (package-with-cortex-a53-guile guile-zlib))

(define zlib-check
  '(begin
     (use-modules (zlib) (rnrs bytevectors))
     (let ((data (string->utf8 "mixed compilation")))
       (unless (bytevector=? data (uncompress (compress data)))
         (error "zlib round trip failed")))))

(with-store store
  (let* ((drv
          (run-with-store store
            (gexp->derivation
             "mixed-aarch64-runtime"
             #~(begin
                 (unless (string=? "aarch64" (utsname:machine (uname)))
                   (error "builder is not executing AArch64 code"))
                 (for-each
                  (lambda (guile)
                    (unless (zero? (system* guile "--no-auto-compile" "-c"
                                            "(display (version)) (newline)"))
                      (error "patched Guile could not execute" guile)))
                  (list #$(file-append guile-3.0/cortex-a53 "/bin/guile")
                        #$(file-append guile-3.0-latest/cortex-a53 "/bin/guile")))
                 (setenv "GUILE_LOAD_PATH" #$(file-append zlib "/share/guile/site/3.0"))
                 (setenv "GUILE_LOAD_COMPILED_PATH"
                         #$(file-append zlib "/lib/guile/3.0/site-ccache"))
                 (unless (zero?
                          (system* #$(file-append guile-3.0/cortex-a53 "/bin/guile")
                                   "--no-auto-compile" "-c"
                                   #$(object->string zlib-check)))
                   (error "native AArch64 consumer could not load with routed Guile"))
                 (call-with-output-file #$output
                   (lambda (port)
                     (display "AArch64 daemon execution and mixed Guile consumer passed\n" port))))
             #:system "aarch64-linux"))))
    (build-derivations store (list drv))
    (display (call-with-input-file (derivation->output-path drv) get-string-all))))
