(define-module (spartan services moonraker)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (spartan packages moonraker)
  #:use-module (srfi srfi-1)
  #:export (%moonraker-default-config
            moonraker-configuration moonraker-configuration?
            moonraker-configuration-package moonraker-configuration-config-file
            moonraker-configuration-data-directory
            moonraker-configuration-klipper-state-directory
            moonraker-configuration-shepherd-requirement moonraker-service-type))

(define %moonraker-default-config
  (local-file "moonraker.conf"))

(define-record-type* <moonraker-configuration>
  moonraker-configuration make-moonraker-configuration moonraker-configuration?
  (package moonraker-configuration-package (default moonraker))
  (config-file moonraker-configuration-config-file
               (default %moonraker-default-config))
  (data-directory moonraker-configuration-data-directory
                  (default "/var/lib/moonraker"))
  (klipper-state-directory moonraker-configuration-klipper-state-directory
                           (default "/var/lib/klipper"))
  (shepherd-requirement moonraker-configuration-shepherd-requirement (default '())))

(define (normalize-moonraker-directory field path)
  (unless (and (string? path) (string-prefix? "/" path))
    (error "Moonraker directory must be an absolute path" field path))
  (let* ((components (remove string-null? (string-split path #\/)))
         (normalized (string-append "/" (string-join components "/"))))
    (when (any (lambda (part) (member part '("." ".."))) components)
      (error "Moonraker directory must not contain . or .. components" field path))
    (when (or (member normalized '("/" "/var" "/var/lib" "/run" "/gnu" "/gnu/store"))
              (string-prefix? "/gnu/store/" normalized))
      (error "Moonraker directory must be a writable service directory" field path))
    normalized))

(define (validate-moonraker-configuration config)
  (let ((data (normalize-moonraker-directory
               'data-directory (moonraker-configuration-data-directory config)))
        (state (normalize-moonraker-directory
                'klipper-state-directory
                (moonraker-configuration-klipper-state-directory config))))
    ;; The config link must not introduce a cycle or expose private Moonraker
    ;; data as printer configuration through the file API.
    (when (or (string=? data state)
              (string-prefix? (string-append data "/") state)
              (string-prefix? (string-append state "/") data))
      (error "Moonraker data-directory and klipper-state-directory must not overlap"
             data state))
    (validate-moonraker-config-file (moonraker-configuration-config-file config))
    (moonraker-configuration
     (inherit config) (data-directory data) (klipper-state-directory state))))

(define (validate-moonraker-config-file file)
  (unless (or (file-like? file) (and (string? file) (string-prefix? "/" file)))
    (error "Moonraker config-file must be file-like or an absolute path" file)))

(define (moonraker-activation config)
  (let* ((config (validate-moonraker-configuration config))
         (data (moonraker-configuration-data-directory config))
         (state (moonraker-configuration-klipper-state-directory config)))
    (with-imported-modules (source-module-closure '((spartan build moonraker)))
      #~(begin
          (use-modules (spartan build moonraker))
          (let ((account (getpwnam "klipper")))
            (initialize-moonraker-state #$data #$state
                                        (passwd:uid account)
                                        (passwd:gid account)))))))

(define (moonraker-shepherd-services config)
  (let* ((config (validate-moonraker-configuration config))
         (data (moonraker-configuration-data-directory config)))
    (list
     (shepherd-service
      (documentation "Run the Moonraker API server for Klipper.")
      (provision '(moonraker))
      (requirement (append '(user-processes networking klipper)
                           (moonraker-configuration-shepherd-requirement config)))
      (start #~(make-forkexec-constructor
                (list #$(file-append (moonraker-configuration-package config)
                                    "/bin/moonraker")
                      "-d" #$data
                      "-c" #$(moonraker-configuration-config-file config))
                #:user "klipper" #:group "klipper"
                #:directory #$data
                #:environment-variables
                (list #$(string-append "HOME=" data))
                #:log-file #$(string-append data "/logs/shepherd.log")))
      (stop #~(make-kill-destructor))))))

(define moonraker-service-type
  (service-type
   (name 'moonraker)
   (extensions
    (list (service-extension shepherd-root-service-type moonraker-shepherd-services)
          (service-extension activation-service-type moonraker-activation)
          (service-extension profile-service-type
                             (lambda (config)
                               (list (moonraker-configuration-package config))))))
   (default-value (moonraker-configuration))
   (description "Run Moonraker with declarative configuration alongside Klipper.")))
