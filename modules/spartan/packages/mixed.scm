(define-module (spartan packages mixed)
  #:use-module (guix build-system)
  #:use-module ((guix config) #:select (%system))
  #:use-module (guix memoization)
  #:use-module (guix packages)
  #:use-module (guix platform)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:export (package-with-compilation-system))

(define (compilation-target compilation-system system target)
  (let ((destination (gnu-triplet->nix-system (or target system))))
    (and (not (string=? compilation-system destination))
         (or target
             (platform-system->target destination)
             (error "platform has no cross-compilation target" destination)))))

(define package-with-compilation-system
  (memoize
   (lambda* (base #:key (system %system))
     "Return BASE compiled on SYSTEM, defaulting to the Guix runner's native
platform.  Lowering still determines the required output platform: cross-build
only when it differs from SYSTEM.  SYSTEM may be a Guix system or GNU triplet.
The adapter preserves the original outputs without copying their contents."
     (let ((compilation-system (gnu-triplet->nix-system system)))
       (define* (lower name #:key system target #:allow-other-keys)
         ;; Re-evaluate BASE's deferred fields in the selected build context.
         ;; The outer package lowering already selected a replacement, if any.
         (package->bag base compilation-system
                       (compilation-target compilation-system system target)
                       #:graft? #f))

       (define (route-input input)
         (match input
           ((label (? package? dependency) outputs ...)
            (cons* label
                   (package-with-compilation-system
                    dependency #:system compilation-system)
                   outputs))
           (_ input)))

       (package
         (inherit base)
         (location (package-location base))
         (build-system
          (build-system
            (name 'mixed-compilation)
            (description "Compile a package on an explicitly selected platform")
            (lower lower)))
         ;; Profiles and consumers expand propagated inputs outside the bag.
         ;; They must see the same cross-built dependencies as BASE's bag.
         (propagated-inputs
          (let ((target (compilation-target compilation-system
                                            (%current-system)
                                            (%current-target-system))))
            (parameterize ((%current-system compilation-system)
                           (%current-target-system target))
              (let ((inputs (package-propagated-inputs base)))
                (if target (map route-input inputs) inputs)))))
         (replacement
          (let ((target (compilation-target compilation-system
                                            (%current-system)
                                            (%current-target-system))))
            (parameterize ((%current-system compilation-system)
                           (%current-target-system target))
              (and=> (package-replacement base)
                     (lambda (replacement)
                       (package-with-compilation-system
                        replacement #:system compilation-system)))))))))))
