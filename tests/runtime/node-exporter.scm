;; Build the actual policy-selected exporter without rebuilding an entire image:
;; guix build -L modules --system=armhf-linux -f tests/runtime/node-exporter.scm
;; Use --system=aarch64-linux to check the other ARM output architecture.
(use-modules (gnu packages monitoring)
             (guix utils)
             (spartan system build-policy))

(build-policy-package
 (make-build-policy #:system (%current-system)
                    #:mixed-packages (list prometheus-node-exporter))
 prometheus-node-exporter)
