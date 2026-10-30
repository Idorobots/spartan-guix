(define-module (spartan packages cross)
  #:use-module (guix memoization)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:export (package-input-rewriting/cross))

(define (package-input-rewriting/cross replacements)
  "Return a memoized explicit-input rewriter using REPLACEMENTS only for
cross-builds.  Replacement packages must guard their own recipe changes.
Native inputs and implicit build tools are left untouched."
  (define (rewrite-input input)
    (match input
      ((label (? package? package) outputs ...)
       (cons* label (rewrite package) outputs))
      (_ input)))

  (define rewrite
    (mlambdaq (p)
      (or (assq-ref replacements p)
          (package
            (inherit p)
            (location (package-location p))
            ;; Defer selection until lowering, not when the module is loaded
            ;; or the memoized package wrapper is first constructed.
            (inputs
             (if (%current-target-system)
                 (map rewrite-input (package-inputs p))
                 (package-inputs p)))
            (propagated-inputs
             (if (%current-target-system)
                 (map rewrite-input (package-propagated-inputs p))
                 (package-propagated-inputs p)))
            (replacement
             (let ((replacement (package-replacement p)))
               (if (and (%current-target-system) replacement)
                   (rewrite replacement)
                   replacement)))))))

  rewrite)
