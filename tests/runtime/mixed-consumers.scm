;; Optional target-runtime smoke check after selectively cross-building.
;; Run from the channel root: guix repl -L modules tests/runtime/mixed-consumers.scm
(use-modules ((gnu packages admin) #:select (shepherd-1.0))
             ((gnu packages ssh) #:select (guile-ssh))
             (guix derivations)
             (guix gexp)
             (guix monads)
             (guix store)
             (ice-9 textual-ports)
             (spartan packages guile))

(define shepherd (package-with-cortex-a53-guile shepherd-1.0))
(define ssh (package-with-cortex-a53-guile guile-ssh))

(with-store store
  (let ((drv
         (run-with-store store
           (gexp->derivation
            "mixed-shepherd-ssh-runtime"
            #~(begin
                (unless (string=? "aarch64" (utsname:machine (uname)))
                  (error "builder is not executing AArch64 code"))
                ;; Both programs load Shepherd and its target Fibers modules.
                (for-each
                 (lambda (program)
                   (unless (zero? (system* program "--version"))
                     (error "Shepherd program failed to load" program)))
                 (list #$(file-append shepherd "/bin/shepherd")
                       #$(file-append shepherd "/bin/herd")))
                (setenv "GUILE_LOAD_PATH" #$(file-append ssh "/share/guile/site/3.0"))
                (setenv "GUILE_LOAD_COMPILED_PATH"
                        #$(file-append ssh "/lib/guile/3.0/site-ccache"))
                ;; Creating a session exercises the C extension without needing
                ;; a network service or the upstream server-startup harness.
                (unless (zero?
                         (system* #$(file-append guile-3.0/cortex-a53 "/bin/guile")
                                  "--no-auto-compile" "-c"
                                  "(use-modules (ssh session))
                                   (unless (session? (make-session #:host \"127.0.0.1\"))
                                     (error \"Guile-SSH session creation failed\"))"))
                  (error "Guile-SSH target extension failed to load"))
                (call-with-output-file #$output
                  (lambda (port)
                    (display "AArch64 Shepherd/Fibers and Guile-SSH smoke checks passed\n"
                             port))))
            #:system "aarch64-linux"))))
    (build-derivations store (list drv))
    (display (call-with-input-file (derivation->output-path drv) get-string-all))))
