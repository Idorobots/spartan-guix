(define-module (spartan packages go)
  #:use-module (guix build-system)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (go-with-cross-install))

;; Guix 2bc642182 sets GOBIN in setup-go-environment for native and cross
;; builds alike.  Go rejects `go install' of cross-compiled commands when GOBIN
;; is set.  The build policy explicitly selects this helper for Prometheus Node
;; Exporter cross-builds.  Selection is independent of cached dependency outputs.
;;
;; Keep the upstream native bag verbatim.  For a cross bag, let Go install via
;; GOPATH/bin/GOOS_GOARCH, then copy that directory to the output's bin before
;; package-specific post-build phases run.  Source installation, embed files,
;; build flags, tests, and the Go compiler's target/ABI setup remain upstream.
;; A library-only build need not produce a command directory.  Source-only Go
;; recipes can remove setup/build phases altogether; preserve those layouts.
;;
;; The policy selects this lowerer after its native-output availability check.
;; A native substitute hit therefore uses the original derivation.  The helper
;; itself also delegates native lowering unchanged, even when the same package
;; object is lowered natively, cross-compiled, and then lowered natively again.
;;
;; Targeted exporter build and runtime check, from the channel checkout:
;;   exporter=$(guix build -L modules --system=armhf-linux \
;;     -f tests/runtime/node-exporter.scm)
;;   python3 tests/runtime/node-exporter.py "$exporter/bin/node_exporter" linux/arm
;; Use --system=aarch64-linux and linux/arm64 for AArch64.  Running target
;; executables requires native or transparent emulated execution.
;; tests/runtime/go-cross.scm explicitly opts its command fixture into this
;; helper and builds its unmodified library dependency with --no-substitutes.

(define (cross-install-phases phases)
  #~(let* ((phases #$phases)
           (phases
            (if (assq 'setup-go-environment phases)
                (modify-phases phases
                  (add-after 'setup-go-environment 'allow-cross-go-install
                    (lambda _
                      (unsetenv "GOBIN"))))
                phases)))
      (if (assq 'build phases)
          (modify-phases phases
            (add-after 'build 'install-cross-go-commands
              (lambda* (#:key outputs #:allow-other-keys)
                (let ((commands (string-append (getenv "GOPATH") "/bin/"
                                               (getenv "GOOS") "_"
                                               (getenv "GOARCH"))))
                  (when (file-exists? commands)
                    (copy-recursively commands
                                      (string-append (assoc-ref outputs "out") "/bin")))))))
          phases)))

(define (go-with-cross-install base)
  "Correct BASE's Go cross-installation, preserving its exact native derivations.
Select by the lowered bag's target, independently of construction-time parameters."
  (if (eq? 'go/cross-install (build-system-name (package-build-system base)))
      base
      (package/inherit base
        (build-system
         ;; Compute this inside package/inherit so each security replacement
         ;; retains its own original build system, including custom lowerers.
         (let ((bs (package-build-system base)))
           (build-system
             (inherit bs)
             (name 'go/cross-install)
             (lower
              (lambda args
                (let ((lowered (apply (build-system-lower bs) args)))
                  (if (or (not (bag-target lowered))
                          (string=? (gnu-triplet->nix-system (bag-target lowered))
                                    (bag-system lowered)))
                      lowered
                      (bag
                        (inherit lowered)
                        (arguments
                         (substitute-keyword-arguments (bag-arguments lowered)
                           ((#:phases phases #~%standard-phases)
                            (cross-install-phases phases)))))))))))))))
