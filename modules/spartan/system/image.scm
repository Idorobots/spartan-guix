(define-module (spartan system image)
  #:use-module ((gnu bootloader) #:prefix boot:)
  #:use-module (gnu image)
  #:use-module (gnu system)
  #:use-module (gnu system image)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module (spartan system build-policy))

;; Version-pinned bridge for Guix 2bc642182.  system-disk-image has no public
;; builder-system argument.  Delegate unchanged for every OS without a policy;
;; never mutate the genimage/QEMU packages shared with ordinary package builds.
(define original-system-disk-image (@@ (gnu system image) system-disk-image))
(define original-system-image system-image)

(define* (policy-system-disk-image img #:key (name "disk-image") bootcfg
                                  bootloader register-closures? (inputs '()))
  (let ((policy (operating-system-build-policy (image-operating-system img))))
    (define (runtime object)
      (with-parameters ((%current-system (build-policy-system policy))
                       (%current-target-system #f)
                       (%active-build-policy policy)
                       (%build-role 'runtime))
        object))
    (if (not policy)
        (original-system-disk-image img #:name name #:bootcfg bootcfg
                                    #:bootloader bootloader
                                    #:register-closures? register-closures?
                                    #:inputs inputs)
        (with-parameters ((%current-system (build-policy-build-system policy))
                          (%current-target-system #f)
                          (%active-build-policy policy)
                          (%build-role 'build))
          ;; Only the disk-image builder sees these file-like wrappers.  Its OS
          ;; and bootcfg references (including references-graphs) must not become
          ;; host-native or globally cross-compiled when assembly moves hosts.
          (original-system-disk-image
           (image
             (inherit img)
             (operating-system (runtime (image-operating-system img))))
           #:name name #:bootcfg (runtime bootcfg)
           #:bootloader
           (boot:bootloader
             (inherit bootloader)
             (package (runtime (boot:bootloader-package bootloader))))
           #:register-closures? register-closures?
           #:inputs (map (lambda (input)
                           (list (car input) (runtime (cadr input))))
                         inputs))))))

(define (policy-system-image img)
  (let ((policy (operating-system-build-policy (image-operating-system img))))
    (if (and policy (memq (image-format img) '(disk-image compressed-qcow2)))
        (with-parameters ((%current-system (build-policy-system policy))
                          (%current-target-system #f)
                          (%active-build-policy policy)
                          (%build-role 'runtime))
          ;; The upstream entry point calls its private disk-image procedure
          ;; directly in compiled code, so intercept the public entry point.
          (let* ((os (operating-system-for-image img))
                 (image* ((@@ (gnu system image) image-with-os*) img os))
                 (bootcfg (operating-system-bootcfg os))
                 (bootloader (boot:bootloader-configuration-bootloader
                              (operating-system-bootloader os))))
            (policy-system-disk-image
             image* #:bootcfg bootcfg #:bootloader bootloader
             #:register-closures? ((@@ (gnu system image) has-guix-service-type?) os)
             #:inputs `(("system" ,os) ("bootcfg" ,bootcfg)))))
        (original-system-image img))))

(module-set! (resolve-module '(gnu system image)) 'system-image policy-system-image)
