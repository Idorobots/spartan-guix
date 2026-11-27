(use-modules (gnu)
             (gnu image)
             ((gnu packages admin) #:select (shepherd-0.10 shepherd-1.0))
             (gnu packages base)
             (gnu packages guile)
             ((gnu packages package-management) #:select (guix))
             ((gnu packages ssh) #:select (guile-ssh))
             (gnu services shepherd)
             (gnu system image)
             (gnu system images raspberrypi)
             (guix build-system)
             ((guix config) #:select (%system))
             (guix derivations)
             (guix grafts)
             (guix monads)
             (guix packages)
             (guix platform)
             (guix profiles)
             (guix store)
             (guix utils)
             (spartan packages guile)
             (spartan packages guile-config)
             (spartan packages guile-snarf)
             (spartan packages mixed)
             (spartan system build-policy)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "runtime-compilation")

(define available? (@@ (spartan packages mixed) %native-outputs-available?))
(available? (const #f))
(define sdk-fixes (compose guile-with-native-snarf guile-with-native-config))
(define consumers (list shepherd-0.10 shepherd-1.0 guile-ssh guile-readline))
(define selected (append (list guile-3.0 guile-3.0-latest) consumers))
(define (rewriter runtime system)
  (make-mixed-compilation-rewriter #:runtime-system runtime #:system system
                               #:guile-transform sdk-fixes))

(for-each
 (lambda (runtime)
   (let ((target (platform-system->target runtime)))
     (test-assert (string-append runtime ": Guix remains native on a miss")
       (let ((bag (package->bag ((rewriter runtime "x86_64-linux") guix)
                                runtime #f)))
         (and (string=? runtime (bag-system bag)) (not (bag-target bag)))))
     (test-assert (string-append runtime ": all selected packages cross-build on a miss")
       (every (lambda (base)
                (let ((bag (package->bag ((rewriter runtime "x86_64-linux") base)
                                         runtime #f)))
                  (and (string=? "x86_64-linux" (bag-system bag))
                       (string=? target (bag-target bag)))))
              selected))
     (test-assert (string-append runtime ": equal-platform packages stay native without queries")
       (parameterize ((%current-system runtime) (%current-target-system #f)
                      (available? (lambda (p candidate system)
                                    (error "unexpected substitute query"
                                           (package-full-name p) system))))
         (every (lambda (base)
                  (let ((bag (package->bag ((rewriter runtime runtime) base) runtime #f)))
                    (and (string=? runtime (bag-system bag)) (not (bag-target bag)))))
                selected)))
     (test-assert (string-append runtime ": native-output hits retain native builds")
       (parameterize ((available? (const #t)))
         ;; A fresh transform supplies independent adapter identities/decisions.
         (let ((rewrite (make-mixed-compilation-rewriter
                         #:runtime-system runtime #:system "x86_64-linux"
                         #:guile-transform (lambda (p) (package (inherit p))))))
           (every (lambda (base)
                    (let ((bag (package->bag (rewrite base) runtime #f)))
                      (and (string=? runtime (bag-system bag)) (not (bag-target bag)))))
                  selected))))
     (test-assert (string-append runtime ": cross consumers retain build-machine Guile")
       (parameterize ((%current-system "x86_64-linux") (%current-target-system target))
         (every (lambda (base)
                  (let ((p ((rewriter runtime "x86_64-linux") base)))
                    (and (equal? (package-native-inputs base) (package-native-inputs p))
                         (eq? ((rewriter runtime "x86_64-linux")
                               (lookup-package-input base "guile"))
                              (lookup-package-input p "guile")))))
                consumers)))))
 '("armhf-linux" "aarch64-linux"))

(test-assert "runtime context accepts an ARM hard-float GNU triplet"
  (let* ((consumer (package (inherit hello)
                           (inputs (if (string=? (%current-system) "armhf-linux")
                                       (list guile-3.0) '()))))
         (rewrite (rewriter "arm-linux-gnueabihf" "x86_64-linux"))
         (p (rewrite consumer)))
    (parameterize ((%current-system "armhf-linux") (%current-target-system #f))
      (eq? (rewrite guile-3.0) (lookup-package-input p "guile")))))

(test-assert "boards may extend the selected consumer set"
  (let* ((rewrite (make-mixed-compilation-rewriter
                   #:runtime-system "armhf-linux" #:system "x86_64-linux"
                   #:consumers (list hello)))
         (bag (package->bag (rewrite hello) "armhf-linux" #f)))
    (and (string=? "x86_64-linux" (bag-system bag))
         (string=? "arm-linux-gnueabihf" (bag-target bag)))))

(define pi2-systems
  (list rpi2-barebones-os (operating-system-for-image rpi2-barebones-raw-image)))

(test-assert "Pi 2 Guix stays native with aligned keys while Shepherd and kernel stay mixed"
  (every
   (lambda (os)
     (let* ((services (operating-system-services os))
            (config (service-value (fold-services services #:target-type guix-service-type)))
            (guix (guix-configuration-guix config))
            (shepherd (shepherd-configuration-shepherd
                       (service-value (fold-services services
                                                     #:target-type shepherd-root-service-type)))))
       (and (eq? guix (build-policy-package
                      (operating-system-build-policy os)
                      (@ (gnu packages package-management) guix)))
            (every (lambda (key) (eq? guix ((@ (guix gexp) file-append-base) key)))
                   (guix-configuration-authorized-keys config))
            (let ((bag (package->bag guix "armhf-linux" #f)))
              (and (string=? "armhf-linux" (bag-system bag))
                   (not (bag-target bag))))
            (every (lambda (p)
                     (let ((bag (package->bag p "armhf-linux" #f)))
                       (and (string=? %system (bag-system bag))
                            (equal? (and (not (string=? %system "armhf-linux"))
                                         "arm-linux-gnueabihf")
                                    (bag-target bag)))))
                   (list shepherd (operating-system-kernel os))))))
   pi2-systems))

(with-store store
  (define (collision-free? os)
    (parameterize ((%current-system "armhf-linux") (%current-target-system #f) (%graft? #f))
      (run-with-store store
        (check-for-collisions
         (packages->manifest
          (service-value (fold-services (operating-system-services os)
                                        #:target-type profile-service-type)))
         "armhf-linux"))))
  (test-assert "Pi 2 base profiles have consistent propagated libraries"
    (every collision-free? pi2-systems))
  (test-assert "actual ARMHF Guile/Shepherd/kernel derivations execute on the selected runner"
    (every (lambda (base)
             (let ((drv (package-derivation store
                                           ((rewriter "armhf-linux" "x86_64-linux") base)
                                           "armhf-linux" #:graft? #f)))
               (string=? "x86_64-linux" (derivation-system drv))))
           (list guile-3.0-latest shepherd-1.0
                 (operating-system-kernel rpi2-barebones-os)))))

(define runner (test-runner-current))
(test-end "runtime-compilation")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
