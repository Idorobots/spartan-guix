(define-module (spartan services moonraker)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (spartan packages moonraker)
  #:use-module (spartan packages moonraker-provider-shepherd)
  #:use-module (spartan services config-files)
  #:use-module (srfi srfi-1)
  #:export (%moonraker-default-config
            moonraker-configuration moonraker-configuration?
            moonraker-configuration-package moonraker-configuration-config-files
            moonraker-configuration-data-directory
            moonraker-configuration-klipper-state-directory
            moonraker-configuration-managed-services
            moonraker-configuration-power-actions
            moonraker-configuration-shepherd-socket
            moonraker-configuration-shepherd-timeout
            moonraker-config-file moonraker-shepherd-policy moonraker-sudoers-file
            moonraker-configuration-shepherd-requirement moonraker-service-type))

(define %moonraker-default-config
  ;; Expression-based Guix evaluation may omit source locations. Resolve through
  ;; the channel load path rather than the caller's working directory.
  (local-file (canonicalize-path
               (search-path %load-path "spartan/services/moonraker.conf"))))

(define-record-type* <moonraker-configuration>
  moonraker-configuration make-moonraker-configuration moonraker-configuration?
  (package moonraker-configuration-package (default moonraker))
  (config-files moonraker-configuration-config-files
                (default (list (cons "moonraker.conf" %moonraker-default-config))))
  (data-directory moonraker-configuration-data-directory
                  (default "/var/lib/moonraker"))
  (klipper-state-directory moonraker-configuration-klipper-state-directory
                           (default "/var/lib/klipper"))
  (managed-services moonraker-configuration-managed-services
                    (default '(("klipper" start stop restart) ("moonraker" restart))))
  (power-actions moonraker-configuration-power-actions (default '(poweroff reboot)))
  (shepherd-socket moonraker-configuration-shepherd-socket
                   (default "/var/run/shepherd/socket"))
  (shepherd-timeout moonraker-configuration-shepherd-timeout (default 60))
  (shepherd-requirement moonraker-configuration-shepherd-requirement (default '())))

(define (management-service-name? name)
  (and (string? name) (not (string-null? name))
       (not (member name '("root" "shepherd")))
       (every (lambda (char)
                (or (char<=? #\a char #\z) (char<=? #\A char #\Z)
                    (char<=? #\0 char #\9) (memv char '(#\_ #\-))))
              (string->list name))))

(define (validate-management-configuration config)
  (let ((services (moonraker-configuration-managed-services config))
        (power (moonraker-configuration-power-actions config))
        (socket (moonraker-configuration-shepherd-socket config))
        (timeout (moonraker-configuration-shepherd-timeout config)))
    ;; Match the released helper's data contract before serializing policy or
    ;; sudoers commands. In particular, never interpolate arbitrary arguments.
    (unless (and (list? services)
                 (every (lambda (entry)
                          (and (pair? entry) (management-service-name? (car entry))
                               (list? (cdr entry))
                               (every (lambda (action)
                                        (memq action '(start stop restart)))
                                      (cdr entry))
                               (= (length (cdr entry))
                                  (length (delete-duplicates (cdr entry))))
                               (or (not (string=? (car entry) "moonraker"))
                                   (every (lambda (action) (eq? action 'restart))
                                          (cdr entry)))))
                        services)
                 (= (length services)
                    (length (delete-duplicates (map car services))))
                 (assoc "moonraker" services))
      (error "Invalid Moonraker managed-services; Moonraker permits only restart" services))
    (unless (and (list? power)
                 (every (lambda (action) (memq action '(poweroff reboot halt))) power)
                 (= (length power) (length (delete-duplicates power))))
      (error "Invalid Moonraker power-actions" power))
    (unless (and (string? socket) (string-prefix? "/" socket))
      (error "Moonraker shepherd-socket must be absolute" socket))
    (unless (and (real? timeout) (finite? timeout) (> timeout 0))
      (error "Moonraker shepherd-timeout must be finite and positive" timeout))))

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

(define (moonraker-config-source? source)
  (or (file-like? source)
      (and (string? source) (string-prefix? "/" source)
           (not (string-index source #\nul)))))

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
    (validate-config-files 'moonraker (moonraker-configuration-config-files config)
                           #:entry-point "moonraker.conf" #:source? moonraker-config-source?)
    (validate-management-configuration config)
    (moonraker-configuration
     (inherit config) (data-directory data) (klipper-state-directory state))))

(define (moonraker-shepherd-policy config)
  "Return the immutable management policy for CONFIG."
  (let ((config (validate-moonraker-configuration config)))
    (plain-file "moonraker-shepherd-policy.scm"
                (format #f "~s~%"
                        `((version . 1)
                          (socket . ,(moonraker-configuration-shepherd-socket config))
                          (moonraker-service . "moonraker")
                          (services . ,(moonraker-configuration-managed-services config))
                          (power . ,(moonraker-configuration-power-actions config)))))))

(define (moonraker-config-file config)
  "Return the generated entry point beside CONFIG's named application tree."
  (let* ((config (validate-moonraker-configuration config))
         (wrapper (mixed-text-file
                   "moonraker.conf"
                   "[include config/moonraker.conf]\n\n"
                   "[machine]\nprovider: shepherd\nvalidate_service: False\nvalidate_config: False\n"
                   "shepherd_helper: " (file-append moonraker-provider-shepherd
                                                   "/bin/moonraker-shepherd") "\n"
                   "shepherd_policy: " (moonraker-shepherd-policy config) "\n"
                   "shepherd_sudo: /run/privileged/bin/sudo\n"
                   "shepherd_timeout: "
                   (number->string
                    (exact->inexact (moonraker-configuration-shepherd-timeout config))) "\n"))
         ;; Moonraker resolves relative includes from the path used to open
         ;; each file, so the tree works even with runtime symlink targets.
         (tree (file-union
                "moonraker-config"
                (cons (list "moonraker.conf" wrapper)
                      (map (lambda (entry) (list (string-append "config/" (car entry))
                                                 (cdr entry)))
                           (moonraker-configuration-config-files config)))
                #:dangling-symlinks? #t)))
    (file-append tree "/moonraker.conf")))

(define* (moonraker-sudoers-file config #:optional (base %sudoers-specification))
  "Compose BASE sudoers with exact helper permissions derived from CONFIG."
  (unless (file-like? base)
    (error "Moonraker base sudoers must be file-like" base))
  (let* ((config (validate-moonraker-configuration config))
         (policy (moonraker-shepherd-policy config))
         (helper (file-append moonraker-provider-shepherd "/bin/moonraker-shepherd"))
         (commands (append '("capabilities" "status")
                           (append-map
                            (lambda (entry)
                              (map (lambda (action)
                                     (string-append (symbol->string action)
                                                    " " (car entry)))
                                   (cdr entry)))
                            (moonraker-configuration-managed-services config))
                           (map symbol->string
                                (moonraker-configuration-power-actions config))))
         (rules (apply mixed-text-file "moonraker-sudoers-rules"
                       (append-map (lambda (command)
                                     (list "klipper ALL=(root) NOPASSWD: NOSETENV: "
                                           helper " " policy " " command "\n"))
                                   commands))))
    ;; Preserve the host's own file, including relative includes. The operating
    ;; system's sudoers-file builder validates this composition with visudo.
    (mixed-text-file "sudoers" "@include " base "\n@include " rules "\n")))

(define* (moonraker-activation config #:key (user "klipper"))
  (let* ((config (validate-moonraker-configuration config))
         (data (moonraker-configuration-data-directory config))
         (state (moonraker-configuration-klipper-state-directory config))
         ;; Guix's default closure selector only includes Guix's own modules.
         (script
          (program-file "moonraker-activate"
            (with-imported-modules
                (source-module-closure '((spartan build moonraker))
                                       #:select? (lambda (module)
                                                   (memq (car module)
                                                         '(spartan guix gnu))))
              #~(begin
                  (use-modules (spartan build moonraker))
                  (let ((account (getpwnam #$user)))
                    (initialize-moonraker-state #$data #$state
                                                (passwd:uid account)
                                                (passwd:gid account))))))))
    #~(begin
        (use-modules (guix build utils))
        (invoke #$script))))

(define (moonraker-shepherd-services config)
  (let* ((config (validate-moonraker-configuration config))
         (data (moonraker-configuration-data-directory config)))
    (list
     (shepherd-service
      (documentation "Run the Moonraker API server for Klipper.")
      (provision '(moonraker))
      (requirement (append '(user-processes networking)
                           (moonraker-configuration-shepherd-requirement config)))
      (start #~(make-forkexec-constructor
                (list #$(file-append (moonraker-configuration-package config)
                                    "/bin/moonraker")
                      "-d" #$data
                      "-c" #$(moonraker-config-file config))
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
