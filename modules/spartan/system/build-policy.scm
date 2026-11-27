(define-module (spartan system build-policy)
  #:use-module (gnu services)
  #:use-module (gnu services avahi)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu services monitoring)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services ssh)
  #:use-module (gnu system)
  #:use-module ((gnu packages admin) #:select (shepherd-0.10 shepherd-1.0 sudo))
  #:use-module ((gnu packages guile) #:select (guile-readline))
  #:use-module ((gnu packages package-management) #:select (guix))
  #:use-module ((gnu packages ssh) #:select (guile-ssh))
  #:use-module ((guix config) #:select (%system))
  #:use-module (guix gexp)
  #:use-module (guix memoization)
  #:use-module (guix monads)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (guix utils)
  #:use-module (spartan packages build-fixes)
  #:use-module (spartan packages cortex-a53)
  #:use-module (spartan packages guile)
  #:use-module (spartan packages guile-config)
  #:use-module (spartan packages guile-snarf)
  #:use-module (spartan packages mixed)
  #:use-module (spartan services nut)
  #:use-module (spartan services spartan-sensor-mesh)
  #:use-module (srfi srfi-1)
  #:export (make-build-policy
            build-policy? build-policy-system build-policy-build-system
            build-policy-package with-build-policy operating-system-build-policy
            %active-build-policy %build-role))

(define-record-type* <build-policy>
  build-policy %make-build-policy build-policy?
  (system build-policy-system)
  (build-system build-policy-build-system)
  (runtime build-policy-runtime)
  (build build-policy-build)
  (owns? build-policy-owns?))

;; Keep the original recipes so extending/replacing an inherited OS policy does
;; not stack adapters or keep the old board's Guile transformation.
(define %original-packages (make-weak-key-hash-table))

(define* (make-build-policy #:key system (build-system %system)
                           (cortex-a53? #f) (mixed-packages '()))
  "Make an explicitly selected native-first OS build policy.
SYSTEM is the OS output architecture; BUILD-SYSTEM is the runner architecture.
Only MIXED-PACKAGES, Guile and its base consumers may cross-build on native-output
misses.  Cortex-A53 is a required runtime fix, not a substitute-dependent fallback.
Image tools use BUILD-SYSTEM with no runtime transformations."
  (let* ((system (gnu-triplet->nix-system system))
         (build-system (gnu-triplet->nix-system build-system)))
    (when (and cortex-a53? (not (string=? system "aarch64-linux")))
      (error "Cortex-A53 policy requires aarch64-linux" system))
    (let* ((consumers (append (list guix shepherd-0.10 shepherd-1.0
                                   guile-ssh guile-readline sudo)
                             mixed-packages))
           (runtime
           (make-mixed-compilation-rewriter
            #:runtime-system system #:system build-system
            #:guile-transform
            (if cortex-a53?
                (compose guile-with-cortex-a53-fix
                         guile-with-native-snarf guile-with-native-config)
                (compose guile-with-native-snarf guile-with-native-config))
            #:consumers consumers)))
      (call-with-values
          (lambda ()
            (make-native-first-package-mapper
             package-build-fix
             #:select-package
             (lambda (p destination target)
               ;; Dependencies reached only through native/implicit build inputs
               ;; have not necessarily passed through the runtime rewriter yet.
               ;; Match the original object before rewriting, just as at roots.
               ;; Cross requests already have a compilation adapter's recipe.
               (if (and (not target) (not (string=? system build-system))
                        (string=? destination system)
                        (memq p consumers))
                   (runtime p)
                   p))))
        (lambda (fallback owns?)
          (define (remember base selected)
            (hashq-set! %original-packages selected base)
            selected)
          (%make-build-policy
           system build-system
           (memoize (lambda (p) (remember p (fallback (runtime p)))))
           (memoize (lambda (p) (remember p (fallback p))))
           owns?))))))

(define* (build-policy-package policy package #:key (role 'runtime))
  "Select PACKAGE under POLICY.  ROLE is runtime or build (image tooling)."
  (let ((base (or (hashq-ref %original-packages package) package)))
    ((if (eq? role 'build) (build-policy-build policy) (build-policy-runtime policy))
     base)))

(define build-policy-service-type
  (service-type
   (name 'build-policy)
   (extensions '())
   (description "Explicit compilation policy retained by OS/image conversion.")))

(define (operating-system-build-policy os)
  (let ((marker (find (lambda (s) (eq? (service-kind s) build-policy-service-type))
                      (operating-system-user-services os))))
    (and marker (service-value marker))))

(define (with-build-policy os policy)
  "Attach POLICY and route OS packages, firmware, kernel and service packages.
Reapplying a policy replaces the old policy rather than composing board fixes."
  (define (rewrite p) (build-policy-package policy p))
  (define (rewrite-service s)
    (let ((config (service-value s)))
      (cond
       ((eq? (service-kind s) guix-service-type)
        (let* ((base (guix-configuration-guix config)) (selected (rewrite base)))
          (service guix-service-type
                   (guix-configuration
                    (inherit config)
                    (guix selected)
                    (authorized-keys
                     (map (lambda (key)
                            (if (and (file-append? key)
                                     (eq? base (file-append-base key)))
                                (apply file-append selected (file-append-suffix key))
                                key))
                          (guix-configuration-authorized-keys config)))))))
       ((eq? (service-kind s) dbus-root-service-type)
        (service dbus-root-service-type
                 (dbus-configuration (inherit config)
                   (dbus (rewrite ((@@ (gnu services dbus) dbus-configuration-dbus)
                                   config))))))
       ((eq? (service-kind s) udev-service-type)
        (service udev-service-type
                 (udev-configuration (inherit config)
                   (udev (rewrite (udev-configuration-udev config))))))
       ((eq? (service-kind s) avahi-service-type)
        (service avahi-service-type
                 (avahi-configuration (inherit config)
                   (avahi (rewrite (avahi-configuration-avahi config))))))
       ((eq? (service-kind s) openssh-service-type)
        (service openssh-service-type
                 (openssh-configuration (inherit config)
                   (openssh (rewrite (openssh-configuration-openssh config))))))
       ((eq? (service-kind s) prometheus-node-exporter-service-type)
        (service prometheus-node-exporter-service-type
                 (prometheus-node-exporter-configuration (inherit config)
                   (package (rewrite (prometheus-node-exporter-configuration-package config))))))
       ((eq? (service-kind s) upsd-service-type)
        (service upsd-service-type
                 (upsd-configuration (inherit config)
                   (package (rewrite (upsd-configuration-package config))))))
       ((eq? (service-kind s) spartan-sensor-mesh-service-type)
        (service spartan-sensor-mesh-service-type
                 (spartan-sensor-mesh-configuration (inherit config)
                   (nut (and=> (spartan-sensor-mesh-configuration-nut config) rewrite)))))
       (else s))))
  (operating-system
    (inherit os)
    (kernel (rewrite (operating-system-kernel os)))
    (firmware (map rewrite (operating-system-firmware os)))
    (packages (map rewrite (operating-system-packages os)))
    (essential-services
     (modify-services (operating-system-essential-services os)
       (shepherd-root-service-type config =>
         (shepherd-configuration (inherit config)
           (shepherd (rewrite (shepherd-configuration-shepherd config)))))))
    (services
     (cons (service build-policy-service-type policy)
           (map rewrite-service
                (remove (lambda (s) (eq? (service-kind s) build-policy-service-type))
                        (operating-system-user-services os)))))))

;; Guix 2bc642182 has no OS-scoped package transformation hook.  The dispatchers
;; delegate unchanged unless an OS explicitly carries a policy.  In particular,
;; importing Raspberry Pi definitions cannot change an ordinary x86 image.
(define %active-build-policy (make-parameter #f))
(define %build-role (make-parameter 'runtime))
(define %package-compiler ((@@ (guix gexp) lookup-compiler) guix))
(define %package-expander ((@@ (guix gexp) lookup-expander) guix))
(define %os-compiler
  ((@@ (guix gexp) gexp-compiler-lower)
   (@@ (gnu system) operating-system-compiler)))

(define-gexp-compiler policy-package-compiler (struct-vtable guix)
  compiler =>
  (lambda (p system target)
    (let ((policy (%active-build-policy)))
      (%package-compiler
       (if (or (not policy) ((build-policy-owns? policy) p))
           p
           (build-policy-package
            policy p
            #:role (if (and (eq? (%build-role) 'runtime)
                            (string=? (gnu-triplet->nix-system (or target system))
                                      (build-policy-system policy)))
                       'runtime 'build)))
       system target)))
  expander => %package-expander)

(define-gexp-compiler policy-os-compiler
  (@@ (gnu system) <operating-system>)
  compiler =>
  (lambda (os system target)
    (let ((policy (operating-system-build-policy os)))
      (if policy
          (state-with-parameters
           (list %active-build-policy %build-role)
           (list policy 'runtime)
           (%os-compiler os (build-policy-system policy) #f))
          (%os-compiler os system target))))
  expander => (@@ (guix gexp) default-expander))

;; 'guix system build/reconfigure' and deployment can call this monadic entry
;; point directly rather than use the OS gexp compiler.
(define original-operating-system-derivation operating-system-derivation)
(define (policy-operating-system-derivation os)
  (let ((policy (operating-system-build-policy os)))
    (if policy
        (state-parameterize ((%active-build-policy policy)
                            (%build-role 'runtime)
                            (%current-system (build-policy-system policy))
                            (%current-target-system #f))
          (original-operating-system-derivation os))
        (original-operating-system-derivation os))))

(module-set! (resolve-module '(gnu system)) 'operating-system-derivation
             policy-operating-system-derivation)
