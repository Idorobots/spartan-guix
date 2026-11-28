(define-module (spartan packages mixed)
  #:use-module (guix build-system)
  #:use-module ((guix config) #:select (%system))
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix grafts)
  #:use-module (guix memoization)
  #:use-module (guix monads)
  #:use-module (guix packages)
  #:use-module (guix platform)
  #:use-module (guix store)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (ice-9 vlist)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
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

;; A fallback bag can reference packages only through its builder gexps (for
;; example Linux-PAM's configure flags capture an upstream DocBook file-append).
;; Route those references too, but suspend the mapper while lowering each chosen
;; package: a native hit must retain its entire original graph.  Only scoped
;; fallback references re-enable mapping in their own native/cross context.
(define %active-package-mapper (make-parameter #f))
(define %mapper-cache-id (allocate-store-connection-cache 'native-first-lowering))
(define %object-cache-id (@@ (guix store) %object-cache-id))

(define (with-lowering-parameters parameters values thunk)
  ;; Build accumulation suspends and resumes lowering through delimited
  ;; continuations.  Restore the caller's context on suspension and reinstall
  ;; this context on resumption, instead of leaving parameters globally changed
  ;; until the monadic computation eventually completes.
  (lambda (store)
    (let ((previous #f))
      (dynamic-wind
        (lambda () (set! previous (map (lambda (p value) (p value)) parameters values)))
        (lambda () ((thunk) store))
        (lambda () (for-each (lambda (p value) (p value)) parameters previous))))))

(define (with-package-mapper mapper thunk)
  ;; Guix 2bc642182 keys its shared object cache by object/system/target/graft?,
  ;; not by the dynamic compiler context.  Isolate that cache per mapper, also
  ;; for intermediate file-like objects: a cached file-append/computed-file can
  ;; otherwise bypass the package compiler completely.  Keep the unmodified
  ;; context separate and retain nested cache updates when switching back.
  (define (remember context cache contexts)
    (vhash-consq context cache (vhash-delq context contexts)))
  (define (cache-for context contexts)
    (match (vhash-assq context contexts)
      ((_ . cache) cache)
      (#f vlist-null)))
  (lambda (store)
    (let* ((previous (%active-package-mapper))
           (mval (with-lowering-parameters (list %active-package-mapper) (list mapper) thunk)))
      (if (eq? previous mapper)
          (mval store)
          (let* ((contexts (remember previous
                                     (store-connection-cache store %object-cache-id)
                                     (store-connection-cache store %mapper-cache-id)))
                 (selected (set-store-connection-cache
                            (set-store-connection-cache store %mapper-cache-id contexts)
                            %object-cache-id (cache-for mapper contexts))))
            (call-with-values
                (lambda () (mval selected))
              (lambda (value store)
                (let ((contexts
                       (remember mapper
                                 (store-connection-cache store %object-cache-id)
                                 (store-connection-cache store %mapper-cache-id))))
                  (values value
                          (set-store-connection-cache
                           (set-store-connection-cache store %mapper-cache-id contexts)
                           %object-cache-id (cache-for previous contexts)))))))))))

(define %package-compiler
  ((@@ (guix gexp) gexp-compiler-lower) (@@ (guix packages) package-compiler)))
(define-gexp-compiler fallback-package-compiler (@@ (guix packages) <package>)
  compiler =>
  (lambda (p system target)
    (let ((rewrite (%active-package-mapper)))
      (with-package-mapper #f
        (lambda ()
          (%package-compiler (if rewrite (rewrite p) p) system target)))))
  expander =>
  ((@@ (guix gexp) gexp-compiler-expand) (@@ (guix packages) package-compiler)))

(define-record-type <fallback-input>
  (fallback-input mapper object)
  fallback-input?
  (mapper fallback-input-mapper)
  (object fallback-input-object))

(define-gexp-compiler fallback-input-compiler <fallback-input>
  compiler =>
  (lambda (input system target)
    (with-package-mapper (fallback-input-mapper input)
      (lambda ()
        (lower-object (fallback-input-object input) system #:target target))))
  expander => (@@ (guix gexp) default-expander))

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
      ;; Computed sources/snippets can introduce their own package references.
      ;; They need the same scoped cache as references in recipe arguments.
      ((label (? file-like? object) outputs ...)
       (cons* label (scoped-input object) outputs))
      (_ x)))
  ;; Scope mapping to references in recipe arguments, not the whole bag builder:
  ;; build systems can lower their native Guile directly before consuming those
  ;; arguments.  Its original recipe must not inherit the caller's mapper.
  (define scoped-input (memoize (lambda (object) (fallback-input rewrite object))))
  (define (reference object)
    (cond ((gexp? object) (argument object))
          ((pair? object) (cons (reference (car object)) (reference (cdr object))))
          ((file-like? object) (scoped-input object))
          (else object)))
  (define (argument object)
    (cond
     ((gexp? object)
      ((@@ (guix gexp) make-gexp)
       (map (lambda (input)
              (if (gexp-input? input)
                  (gexp-input (reference (gexp-input-thing input))
                              (gexp-input-output input)
                              #:native? (gexp-input-native? input))
                  input))
            ((@@ (guix gexp) gexp-references) object))
       ((@@ (guix gexp) gexp-self-modules) object)
       (map reference ((@@ (guix gexp) gexp-self-extensions) object))
       ((@@ (guix gexp) gexp-proc) object)
       ((@@ (guix gexp) %gexp-location) object)))
     ((pair? object) (cons (argument (car object)) (argument (cdr object))))
     ;; Some build systems also retain SOURCE as a file-like keyword argument.
     ;; Leave package-valued arguments such as #:guile to the build system.
     ((and (not (package? object)) (file-like? object)) (scoped-input object))
     (else object)))
  (define (fallback base system target)
    (let* ((fixed (transform base (gnu-triplet->nix-system (or target system))))
           (bs (package-build-system fixed)))
      (define (lower . args)
        (let ((lowered (apply (build-system-lower bs) args)))
          (bag
            (inherit lowered)
            (build-inputs (map input (bag-build-inputs lowered)))
            (host-inputs (map input (bag-host-inputs lowered)))
            (target-inputs (map input (bag-target-inputs lowered)))
            (arguments (argument (bag-arguments lowered))))))
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
                 (%active-package-mapper #f)
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
                      (%active-package-mapper #f)
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
