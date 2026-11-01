;; Optional integration check, requiring AArch64 daemon execution/offloading.
;; From the channel root: guix repl -L modules tests/runtime/guile-sdk.scm
(use-modules (gnu packages base)
             (gnu packages guile)
             (gnu packages pkg-config)
             (gnu system images raspberrypi)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (spartan packages guile)
             (spartan packages guile-config)
             (spartan packages guile-snarf)
             (srfi srfi-1))

(define sdk-package
  (make-guile-runtime-rewriter
   #:guile-transform (compose guile-with-native-snarf guile-with-native-config)))

(define (sdk-check guile rewrite)
  (rewrite
   (package
     (inherit hello)
     (name "native-guile-sdk-check")
     (version (package-version guile))
     (source #f)
     (inputs (list guile))
     (native-inputs (list pkg-config))
     (arguments
      (list
       #:modules '((guix build gnu-build-system)
                   (guix build utils)
                   (ice-9 popen)
                   (ice-9 textual-ports)
                   (srfi srfi-13))
       #:phases
       #~(modify-phases %standard-phases
           (delete 'unpack)
           (delete 'bootstrap)
           (delete 'configure)
           (replace 'build
             (lambda* (#:key inputs #:allow-other-keys)
               (define (config-flags command)
                 (let* ((pipe (open-pipe* OPEN_READ
                                         (search-input-file inputs "/bin/guile-config")
                                         command))
                        (text (get-string-all pipe))
                        (status (close-pipe pipe)))
                   (unless (zero? status)
                     (error "guile-config failed" command status))
                   (string-tokenize text)))
               (when (which "aarch64-linux-gnu-gcc")
                 (error "SDK regression requires native tools, not a cross compiler"))
               (copy-file #$(local-file "guile-sdk.c") "probe.c")
               (let ((cflags (config-flags "compile"))
                     (libs (config-flags "link")))
                 (apply invoke (search-input-file inputs "/bin/guile-snarf")
                        "-o" "probe.x" (append cflags '("probe.c")))
                 (apply invoke "gcc" "-shared" "-fPIC" "-o" "probe.so"
                        "probe.c" (append cflags libs)))))
           (replace 'check
             (lambda* (#:key inputs #:allow-other-keys)
               (invoke (search-input-file inputs "/bin/guile")
                       "--no-auto-compile" "-c"
                       (object->string
                        `(begin
                           (load-extension ,(string-append (getcwd) "/probe.so")
                                           "scm_init_mixed_probe")
                           (unless (string=? "mixed compilation" (mixed-probe))
                             (error "native extension returned the wrong value")))))))
           (replace 'install
             (lambda* (#:key outputs #:allow-other-keys)
               (let ((lib (string-append (assoc-ref outputs "out") "/lib")))
                 (mkdir-p lib)
                 (copy-file "probe.so" (string-append lib "/probe.so")))))))))))

(with-store store
  (let ((derivations
         (append-map
          (lambda (rewrite)
            (map (lambda (guile)
                   (package-derivation store (sdk-check guile rewrite) "aarch64-linux"))
                 (list guile-3.0 guile-3.0-latest)))
          (list sdk-package rpi3-package))))
    (build-derivations store derivations)
    (for-each (lambda (drv)
                (format #t "PASS: native guile-snarf, guile-config and C extension: ~a~%"
                        (derivation->output-path drv)))
              derivations)))
