(define-module (spartan services klipper)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system shadow)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix modules)
  #:use-module (spartan packages klipper)
  #:use-module (spartan services config-files)
  #:use-module (srfi srfi-1)
  #:export (klipper-configuration klipper-configuration?
            klipper-configuration-package klipper-configuration-config-files
            klipper-configuration-state-directory klipper-configuration-run-directory
            klipper-configuration-firmware-workspace?
            klipper-configuration-shepherd-requirement klipper-service-type))

(define-record-type* <klipper-configuration>
  klipper-configuration make-klipper-configuration klipper-configuration?
  (package klipper-configuration-package (default klipper))
  (config-files klipper-configuration-config-files)
  (state-directory klipper-configuration-state-directory
                   (default "/var/lib/klipper"))
  (run-directory klipper-configuration-run-directory (default "/run/klipper"))
  (firmware-workspace? klipper-configuration-firmware-workspace? (default #f))
  (shepherd-requirement klipper-configuration-shepherd-requirement (default '())))

(define (normalize-klipper-directory field path)
  (unless (and (string? path) (string-prefix? "/" path))
    (error "Klipper directory must be an absolute path" field path))
  ;; Normalize lexically: these directories may not exist on the build host.
  ;; Reject dot components rather than interpreting paths through symlinks.
  (let* ((components (remove string-null? (string-split path #\/)))
         (normalized (string-append "/" (string-join components "/"))))
    (when (any (lambda (component) (member component '("." ".."))) components)
      (error "Klipper directory must not contain . or .. components" field path))
    (when (or (member normalized '("/" "/var" "/run" "/gnu/store"))
              (string-prefix? "/gnu/store/" normalized))
      (error "Klipper directory must be a writable service directory" field path))
    normalized))

(define (validate-klipper-configuration config)
  (let ((state (normalize-klipper-directory
                'state-directory (klipper-configuration-state-directory config)))
        (run (normalize-klipper-directory
              'run-directory (klipper-configuration-run-directory config))))
    (when (string=? state run)
      (error "Klipper state-directory and run-directory must be distinct" state run))
    (unless (boolean? (klipper-configuration-firmware-workspace? config))
      (error "Klipper firmware-workspace? must be a boolean"
             (klipper-configuration-firmware-workspace? config)))
    (validate-config-files 'klipper (klipper-configuration-config-files config)
                           #:entry-point "printer.cfg" #:reserved '("klippy.log"))
    (klipper-configuration
     (inherit config)
     (state-directory state)
     (run-directory run))))

(define* (klipper-activation config #:key (user "klipper"))
  (let* ((config (validate-klipper-configuration config))
         (state (klipper-configuration-state-directory config))
         (run (klipper-configuration-run-directory config))
         (files (klipper-configuration-config-files config))
         (entry (assoc "printer.cfg" files))
         ;; Publish the entry point last on a fresh install.
         (seeds (map (lambda (seed) #~(cons #$(car seed) #$(cdr seed)))
                     (append (delq entry files) (list entry))))
         (firmware-source
          (and (klipper-configuration-firmware-workspace? config)
               (file-append (klipper-configuration-package config)
                             "/share/klipper")))
         ;; Guix's default closure selector only includes Guix's own modules.
         (script
          (program-file "klipper-activate"
            (with-imported-modules
                (source-module-closure '((spartan build klipper))
                                       #:select? (lambda (module)
                                                   (memq (car module)
                                                         '(spartan guix gnu))))
              #~(begin
                  (use-modules (spartan build klipper))
                  (let ((account (getpwnam #$user)))
                     (initialize-klipper-state #$state #$run (list #$@seeds)
                                              (passwd:uid account)
                                              (passwd:gid account)
                                              #:firmware-source #$firmware-source)))))))
    #~(begin
        (use-modules (guix build utils))
        (invoke #$script))))

(define (klipper-shepherd-services config)
  (let* ((config (validate-klipper-configuration config))
         (package (klipper-configuration-package config))
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
