(define-module (spartan packages mixed)
  #:use-module (guix build-system)
  #:use-module ((guix config) #:select (%system))
  #:use-module (guix derivations)
  #:use-module (guix grafts)
  #:use-module (guix memoization)
  #:use-module (guix packages)
  #:use-module (guix platform)
  #:use-module (guix store)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (package-with-compilation-system))

(define* (native-outputs-available? store package system
                                    #:key (valid? valid-path?)
                                    (substitutes substitutable-paths))
  ;; Only inspect outputs.  Graft analysis can realize prerequisites, so keep it
  ;; disabled for this query; normal grafting of the chosen package is unchanged.
  (parameterize ((%current-system system)
                 (%current-target-system #f)
                 (%graft? #f))
    (let* ((drv (package-derivation store package system #:graft? #f))
           (paths (map (lambda (output) (derivation-output-path (cdr output)))
                       (derivation-outputs drv)))
           (missing (remove (lambda (path) (valid? store path)) paths)))
      (or (null? missing)
          (and (substitutable-derivation? drv)
               (let ((available (substitutes store missing)))
                 (every (lambda (path) (member path available)) missing)))))))

(define* (native-candidate-usable? store package candidate system
                                   #:key (valid? valid-path?)
                                   (substitutes substitutable-paths))
  (and (native-outputs-available? store package system
                                  #:valid? valid? #:substitutes substitutes)
       ;; A native output embeds its original propagated paths.  A routed
       ;; candidate must match them exactly or the resulting profile diverges.
       (parameterize ((%current-system system)
                      (%current-target-system #f)
                      (%graft? #f))
         (string=?
          (derivation-file-name
           (package-derivation store package system #:graft? #f))
          (derivation-file-name
           (package-derivation store candidate system #:graft? #f))))))

;; Private so tests can model hits and misses without relying on cache state.
(define %native-outputs-available?
  (make-parameter
   (lambda (package candidate system)
     (with-store store
       (native-candidate-usable? store package candidate system)))))

(define (compilation-target compilation-system system target)
  (let ((destination (gnu-triplet->nix-system (or target system))))
    (and (not (string=? compilation-system destination))
         (or target
             (platform-system->target destination)
             (error "platform has no cross-compilation target" destination)))))

(define package-with-compilation-system
  (memoize
   (lambda* (base #:key (system %system))
     "Prefer BASE's native outputs when local or substitutable, otherwise compile
on SYSTEM, defaulting to the Guix runner's native platform.  Determine the output
platform during lowering; same-platform requests remain native without a query.
Availability decisions are lazy and memoized in memory.  Apply recipe fixes
before adaptation.  Preserve original output paths without copying contents."
     (let ((fallback-system (gnu-triplet->nix-system system)))
       (define (route-input input)
         (match input
           ((label (? package? dependency) outputs ...)
            (cons* label
                   (package-with-compilation-system
                    dependency #:system fallback-system)
                   outputs))
           (_ input)))

       ;; The bag and profiles must use the same propagated library choices.
       ;; In particular, Guile and Readline copy the same library list upstream;
       ;; route it once here rather than force cross copies only in metadata.
       (define candidate
         (package
           (inherit base)
           (location (package-location base))
           (propagated-inputs (map route-input (package-propagated-inputs base)))))

       (define compilation-system-for
         (memoize
          (lambda (destination)
            (if (or (string=? fallback-system destination)
                    ((%native-outputs-available?) base candidate destination))
                destination
                fallback-system))))

       (define* (lower name #:key system target #:allow-other-keys)
         (let* ((destination (gnu-triplet->nix-system (or target system)))
                (compilation-system (compilation-system-for destination)))
           ;; Check the exact native candidate before applying a cross override.
           (package->bag candidate compilation-system
                         (compilation-target compilation-system system target)
                         #:graft? #f)))

       (package
         (inherit candidate)
         (location (package-location base))
         (build-system
          (build-system
            (name 'mixed-compilation)
            (description "Prefer native substitutes, otherwise compile on a selected platform")
            (lower lower)))
         (propagated-inputs
          (let* ((destination (gnu-triplet->nix-system
                               (or (%current-target-system) (%current-system))))
                 (compilation-system (compilation-system-for destination))
                 (target (compilation-target compilation-system
                                             (%current-system)
                                             (%current-target-system))))
            (parameterize ((%current-system compilation-system)
                           (%current-target-system target))
              (package-propagated-inputs candidate))))
         (replacement
          (let* ((destination (gnu-triplet->nix-system
                               (or (%current-target-system) (%current-system))))
                 (compilation-system (compilation-system-for destination))
                 (target (compilation-target compilation-system
                                             (%current-system)
                                             (%current-target-system))))
            (parameterize ((%current-system compilation-system)
                           (%current-target-system target))
              (and=> (package-replacement base)
                     (lambda (replacement)
                       (package-with-compilation-system
                        replacement #:system fallback-system)))))))))))
