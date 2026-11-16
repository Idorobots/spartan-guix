(define-module (spartan services klipper)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system shadow)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix modules)
  #:use-module (spartan packages klipper)
  #:use-module (srfi srfi-1)
  #:export (klipper-configuration klipper-configuration?
            klipper-configuration-package klipper-configuration-config-file
            klipper-configuration-state-directory klipper-configuration-run-directory
            klipper-configuration-firmware-workspace?
            klipper-configuration-shepherd-requirement klipper-service-type))

(define-record-type* <klipper-configuration>
  klipper-configuration make-klipper-configuration klipper-configuration?
  (package klipper-configuration-package (default klipper))
  (config-file klipper-configuration-config-file)
  (state-directory klipper-configuration-state-directory
                   (default "/var/lib/klipper"))
  (run-directory klipper-configuration-run-directory (default "/run/klipper"))
  (firmware-workspace? klipper-configuration-firmware-workspace? (default #f))
  (shepherd-requirement klipper-configuration-shepherd-requirement (default '())))

(define (klipper-activation config)
  (let ((state (klipper-configuration-state-directory config))
        (run (klipper-configuration-run-directory config))
        (seed (klipper-configuration-config-file config))
        (firmware-source
         (and (klipper-configuration-firmware-workspace? config)
              (file-append (klipper-configuration-package config)
                           "/share/klipper"))))
    (define (usable-directory? path)
      (and (string? path) (string-prefix? "/" path)
           (not (member path '("/" "/var" "/run" "/gnu/store")))
           (not (string-prefix? "/gnu/store/" path))
           (every (lambda (component) (not (member component '("." ".."))))
                  (string-split path #\/))))
    (unless (and (usable-directory? state) (usable-directory? run)
                 (not (string=? state run)))
      (error "Klipper requires distinct writable absolute state and run directories"))
    (with-imported-modules (source-module-closure '((spartan build klipper)))
      #~(begin
          (use-modules (spartan build klipper))
          (let ((account (getpwnam "klipper")))
            (initialize-klipper-state #$state #$run #$seed
                                      (passwd:uid account)
                                      (passwd:gid account)
                                      #:firmware-source #$firmware-source))))))

(define (klipper-shepherd-services config)
  (let ((package (klipper-configuration-package config))
        (state (klipper-configuration-state-directory config))
        (run (klipper-configuration-run-directory config)))
    (list
     (shepherd-service
      (documentation "Run the Klipper host software.")
      (provision '(klipper))
      (requirement (append '(user-processes udev)
                           (klipper-configuration-shepherd-requirement config)))
      (start #~(make-forkexec-constructor
                (list #$(file-append package "/bin/klippy")
                      #$(string-append state "/printer.cfg")
                      "-l" #$(string-append state "/klippy.log")
                      "-I" #$(string-append run "/printer")
                      "-a" #$(string-append run "/klippy.sock"))
                #:user "klipper" #:group "klipper"
                #:supplementary-groups '("dialout")))
      (stop #~(make-kill-destructor))))))

(define klipper-service-type
  (service-type
   (name 'klipper)
   (extensions
    (list (service-extension shepherd-root-service-type klipper-shepherd-services)
          (service-extension activation-service-type klipper-activation)
          (service-extension account-service-type
                             (const (list (user-group (name "klipper") (system? #t))
                                          (user-account
                                           (name "klipper") (group "klipper")
                                           (system? #t)
                                           (supplementary-groups '("dialout"))
                                           (home-directory "/var/empty")
                                           (shell (file-append
                                                   (@ (gnu packages admin) shadow)
                                                   "/sbin/nologin"))))))
          (service-extension profile-service-type
                             (lambda (config)
                               (list (klipper-configuration-package config))))))
   (description "Run Klipper with an initially declarative, writable printer configuration.")))
