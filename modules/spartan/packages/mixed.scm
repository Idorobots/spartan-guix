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
  #:export (package-with-compilation-system
            map-compilation-package
            make-compilation-package-mapper
            make-native-first-package-mapper
            native-outputs-available?
            native-package-outputs-available?))

;; Keep recipe transformations inside an adapter: changing the arguments on
;; the outer package would leave the recipe captured by its lowerer unchanged.
(define %compilation-packages (make-weak-key-hash-table))
(define %compilation-fallbacks (make-weak-key-hash-table))

(define (map-compilation-package transform package)
  "Apply TRANSFORM to PACKAGE's recipe, retaining any compilation adapters."
  (match (hashq-ref %compilation-packages package)
    ((base . system)
     (package-with-compilation-system
      (map-compilation-package transform base) #:system system
      #:fallback (or (hashq-ref %compilation-fallbacks package) identity)))
    (#f (transform package))))

(define* (make-compilation-package-mapper transform #:key (deep? #t))
  "Return a memoized dependency mapper applying TRANSFORM inside adapters.
TRANSFORM changes a single recipe; explicit dependencies, graft replacements,
and, when DEEP? is true, implicit build inputs are visited recursively.  Adapted
packages are unwrapped, mapped and adapted again with their original compilation
platform.  This keeps recipe fixes inside the lowerer's captured recipe."
  (define (adapted? package)
    (hashq-ref %compilation-packages package))

  (define (rewrite-input input)
    (match input
      ((label (? package? package) outputs ...)
       (cons* label (rewrite package) outputs))
      (_ input)))

  (define (mapped-build-system system)
    (define lower (build-system-lower system))
    (build-system
      (inherit system)
      (lower
       (lambda args
         (let ((lowered (apply lower args)))
           (bag
             (inherit lowered)
             (build-inputs (map rewrite-input (bag-build-inputs lowered)))
             (host-inputs (map rewrite-input (bag-host-inputs lowered)))
             (target-inputs (map rewrite-input (bag-target-inputs lowered)))))))))

  ;; Let Guix handle explicit inputs, replacements and memoization.  Its deep
  ;; mapper would also clone adapted packages *after* our transformation, losing
  ;; their adapter registration.  Instead handle implicit inputs only on plain
  ;; recipes, and cut recursion at adapters after mapping their captured recipe.
  (define rewrite
    (package-mapping
     (lambda (package)
       (if (adapted? package)
           (map-compilation-package rewrite package)
           (let ((selected (transform package)))
             (if deep?
                 (package/inherit selected
                   (build-system
                    (mapped-build-system (package-build-system selected))))
                 selected))))
     adapted?
     #:deep? #f))
  rewrite)

(define* (make-native-first-package-mapper transform
                                          #:key (select-package
                                                 (lambda (p system target) p)))
  "Return two procedures: a lazy native-first mapper and its ownership predicate.
TRANSFORM takes a recipe and its output system.  An exact native hit retains the
entire original graph.  Only a miss visits explicit and implicit fallback inputs.
Compilation adapters are retained, so each input is selected in its own eventual
native/cross context, rather than the enclosing image's architecture.
SELECT-PACKAGE may select an adapter for a newly encountered fallback dependency;
it runs only after the original native-output check misses."
  (define owned (make-weak-key-hash-table))
  (define (owns? p)
    (or (hashq-ref owned p)
        (eq? rewrite (hashq-ref %compilation-fallbacks p))))
  (define (input x)
    (match x
      ((label (? package? p) outputs ...) (cons* label (rewrite p) outputs))
      (_ x)))
  (define (fallback base system target)
    (let* ((fixed (transform base (gnu-triplet->nix-system (or target system))))
           (bs (package-build-system fixed)))
      (define (lower . args)
        (let ((lowered (apply (build-system-lower bs) args)))
          (bag
            (inherit lowered)
            (build-inputs (map input (bag-build-inputs lowered)))
            (host-inputs (map input (bag-host-inputs lowered)))
            (target-inputs (map input (bag-target-inputs lowered))))))
      (package
        (inherit fixed)
        (inputs (map input (package-inputs fixed)))
        (native-inputs (map input (package-native-inputs fixed)))
        (propagated-inputs (map input (package-propagated-inputs fixed)))
        (replacement (and=> (package-replacement fixed) rewrite))
        (build-system (build-system (inherit bs) (lower lower))))))
  (define rewrite
    (memoize
     (lambda (base)
       (if (owns? base)
           base
           (let ((adapter (hashq-ref %compilation-packages base)))
             (define choose
               (memoize
                (lambda (system target)
                  (parameterize ((%current-system system)
                                 (%current-target-system target))
                    (if (and (not target)
                             (native-package-outputs-available? base system))
                        base
                         (let ((selected (select-package base system target)))
                           (if (eq? base selected)
                               (fallback base system target)
                               (rewrite selected))))))))
             (define selected
               (if adapter
                   ;; Keep the original candidate outside the fallback adapter.
                   ;; Inheriting a captured lowerer and changing its propagated
                   ;; fields would otherwise change profile metadata but not
                   ;; the actual bag, hiding incompatible native library paths.
                   (package-with-compilation-system (car adapter)
                                                    #:system (cdr adapter)
                                                    #:fallback rewrite)
                   (package
                     (inherit base)
                     (build-system
                      (build-system
                        (name 'native-first)
                        (description "Select original native outputs before source-build fixes")
                        (lower
                         (lambda* (name #:key system target #:allow-other-keys)
                           (package->bag (choose system target) system target
                                         #:graft? #f)))))
                     (propagated-inputs
                      (package-propagated-inputs
                       (choose (%current-system) (%current-target-system))))
                     (replacement
                      (package-replacement
                       (choose (%current-system) (%current-target-system)))))))
             (hashq-set! owned selected #t)
             selected)))))
  (values rewrite owns?))

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

(define* (native-package-outputs-available? package system
                                            #:optional (candidate package))
  "Whether PACKAGE's native outputs for SYSTEM are local or substitutable.
CANDIDATE defaults to PACKAGE and must have the same derivation for an exact
native hit."
  ((%native-outputs-available?) package candidate system))

(define (compilation-target compilation-system system target)
  (let ((destination (gnu-triplet->nix-system (or target system))))
    (and (not (string=? compilation-system destination))
         (or target
             (platform-system->target destination)
             (error "platform has no cross-compilation target" destination)))))

(define package-with-compilation-system
  (memoize
   (lambda* (base #:key (system %system) (fallback identity))
     "Prefer BASE's native outputs when local or substitutable, otherwise compile
on SYSTEM, defaulting to the Guix runner's native platform.  Determine the output
platform during lowering; same-platform compilation selection needs no query.
FALLBACK receives the routed recipe only on a miss or a same-platform request;
it may independently select source-build fixes.  Availability decisions are lazy
and memoized in memory.  Required recipe changes precede adaptation.  Preserve
original output paths without copying contents."
     (let ((fallback-system (gnu-triplet->nix-system system)))
       (define (route-input input)
         (match input
           ((label (? package? dependency) outputs ...)
            (cons* label
                   (package-with-compilation-system
                    dependency #:system fallback-system #:fallback fallback)
                   outputs))
           (_ input)))

       ;; The bag and profiles must use the same propagated library choices.
       ;; In particular, Guile and Readline copy the same library list upstream;
       ;; route it once here rather than force cross copies only in metadata.
       (define candidate
         (package
           (inherit base)
           (location (package-location base))
           (replacement (package-replacement base))
           (propagated-inputs (map route-input (package-propagated-inputs base)))))

       (define selection-for
         (memoize
          (lambda (destination)
            (cond
             ((string=? fallback-system destination) (cons destination #f))
             (((%native-outputs-available?) base candidate destination)
              (cons destination #t))
             (else (cons fallback-system #f))))))

       (define (recipe-for destination)
         (if (cdr (selection-for destination)) candidate (fallback candidate)))

       (define* (lower name #:key system target #:allow-other-keys)
         (let* ((destination (gnu-triplet->nix-system (or target system)))
                (compilation-system (car (selection-for destination))))
           ;; Check the exact native candidate before applying a cross override.
           (package->bag (recipe-for destination) compilation-system
                         (compilation-target compilation-system system target)
                         #:graft? #f)))

       (define adapted
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
                   (compilation-system (car (selection-for destination)))
                   (target (compilation-target compilation-system
                                               (%current-system)
                                               (%current-target-system))))
              (parameterize ((%current-system compilation-system)
                             (%current-target-system target))
                (package-propagated-inputs (recipe-for destination)))))
           (replacement
            (let* ((destination (gnu-triplet->nix-system
                                 (or (%current-target-system) (%current-system))))
                   (compilation-system (car (selection-for destination)))
                   (target (compilation-target compilation-system
                                               (%current-system)
                                               (%current-target-system))))
              (parameterize ((%current-system compilation-system)
                             (%current-target-system target))
                (and=> (package-replacement (recipe-for destination))
                       (lambda (replacement)
                         (package-with-compilation-system
                          replacement #:system fallback-system
                          #:fallback fallback))))))))
       (hashq-set! %compilation-packages adapted (cons base fallback-system))
       (hashq-set! %compilation-fallbacks adapted fallback)
       adapted))))
