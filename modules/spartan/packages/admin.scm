(define-module (spartan packages admin)
  #:use-module (gnu packages admin)
  #:use-module (spartan packages linux)
  #:export (htop/cross-fixed))

(define htop/cross-fixed
  ;; Keep the monitoring dependency fixes behind a single package variant.
  (package-with-cross-fixed-lm-sensors htop))
