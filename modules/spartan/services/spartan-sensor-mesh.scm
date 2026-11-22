;; SPDX-License-Identifier: MIT
(define-module (spartan services spartan-sensor-mesh)
  #:use-module (gnu packages admin)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (gnu system shadow)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (spartan packages spartan-sensor-mesh)
  #:use-module (srfi srfi-1)
  #:export (%spartan-sensor-mesh-default-data-directory
            %spartan-sensor-mesh-default-log-file
            spartan-sensor-mesh-configuration
            spartan-sensor-mesh-configuration?
            spartan-sensor-mesh-configuration-package
            spartan-sensor-mesh-configuration-config-file
            spartan-sensor-mesh-configuration-application-config
            spartan-sensor-mesh-configuration-ui-root
            spartan-sensor-mesh-configuration-rest-host
            spartan-sensor-mesh-configuration-rest-port
            spartan-sensor-mesh-configuration-nut
            spartan-sensor-mesh-configuration-user
            spartan-sensor-mesh-configuration-group
            spartan-sensor-mesh-configuration-data-directory
            spartan-sensor-mesh-configuration-log-file
            spartan-sensor-mesh-configuration-shepherd-requirement
            spartan-sensor-mesh-configuration-environment-variables
            spartan-sensor-mesh-service-type))

(define %spartan-sensor-mesh-default-data-directory
  "/var/lib/spartan-sensor-mesh")

(define %spartan-sensor-mesh-default-log-file
  "/var/lib/spartan-sensor-mesh/shepherd.log")

(define-record-type* <spartan-sensor-mesh-configuration>
  spartan-sensor-mesh-configuration
  make-spartan-sensor-mesh-configuration
  spartan-sensor-mesh-configuration?
  (package spartan-sensor-mesh-configuration-package
           (default spartan-sensor-mesh))
  (config-file spartan-sensor-mesh-configuration-config-file (default #f))
  (application-config spartan-sensor-mesh-configuration-application-config
                      (default #f))
  (ui-root spartan-sensor-mesh-configuration-ui-root (default #f))
  (rest-host spartan-sensor-mesh-configuration-rest-host (default #f))
  (rest-port spartan-sensor-mesh-configuration-rest-port (default #f))
  (nut spartan-sensor-mesh-configuration-nut (default #f))
  (user spartan-sensor-mesh-configuration-user (default "ssm"))
  (group spartan-sensor-mesh-configuration-group (default "ssm"))
  (data-directory spartan-sensor-mesh-configuration-data-directory
                  (default %spartan-sensor-mesh-default-data-directory))
  (log-file spartan-sensor-mesh-configuration-log-file
            (default %spartan-sensor-mesh-default-log-file))
  (shepherd-requirement
   spartan-sensor-mesh-configuration-shepherd-requirement (default '()))
  (environment-variables
   spartan-sensor-mesh-configuration-environment-variables (default '())))

(define (absolute-path? path)
  (and (string? path)
       (string-prefix? "/" path)
       (not (string-null? path))))

(define (config-source? value)
  (or (file-like? value)
      (and (absolute-path? value)
           (not (string-index value #\nul)))))

(define (validate-config-source field value)
  (when (and value (not (config-source? value)))
    (error "Spartan Sensor Mesh configuration source must be a file-like object or absolute path"
           field value)))

(define (valid-account-name? name)
  (and (string? name)
       (not (string-null? name))
       (not (string=? name "root"))
       (every (lambda (char)
                (and (not (char=? char #\:))
                     (not (char=? char #\newline))
                     (not (char=? char #\nul))))
              (string->list name))))

(define (validate-account-name field name)
  (unless (valid-account-name? name)
    (error "Spartan Sensor Mesh account name is invalid" field name)))

(define (normalize-data-directory directory)
  (unless (absolute-path? directory)
    (error "Spartan Sensor Mesh data directory must be an absolute path"
           directory))
  (let* ((components (filter (lambda (part) (not (string-null? part)))
                             (string-split directory #\/)))
         (normalized (string-append "/" (string-join components "/"))))
    (when (or (member ".." components)
              (string=? normalized "/")
              (string=? normalized "/gnu")
              (string=? normalized "/gnu/store")
              (string-prefix? "/gnu/store/" normalized)
              (string=? normalized "/var")
              (string=? normalized "/var/lib"))
      (error "Spartan Sensor Mesh data directory must be a dedicated writable directory"
             directory))
    normalized))

(define (validate-log-file log)
  (when log
    (unless (and (absolute-path? log)
                 (not (string-prefix? "/gnu/store/" log)))
      (error "Spartan Sensor Mesh log file must be an absolute runtime path"
             log))))

(define (validate-rest-host host)
  (when (and host (not (and (string? host) (not (string-null? host)))))
    (error "Spartan Sensor Mesh REST host must be a non-empty string" host)))

(define (validate-rest-port port)
  (when (and port
             (not (and (integer? port) (exact? port) (<= 1 port 65535))))
    (error "Spartan Sensor Mesh REST port must be an integer between 1 and 65535"
           port)))

(define (validate-spartan-sensor-mesh-configuration config)
  (let ((package (spartan-sensor-mesh-configuration-package config))
        (data (normalize-data-directory
               (spartan-sensor-mesh-configuration-data-directory config)))
        (user (spartan-sensor-mesh-configuration-user config))
        (group (spartan-sensor-mesh-configuration-group config))
        (requirements
         (spartan-sensor-mesh-configuration-shepherd-requirement config))
        (environment
         (spartan-sensor-mesh-configuration-environment-variables config)))
    (unless (package? package)
      (error "Spartan Sensor Mesh package must be a package" package))
    (validate-config-source
     'config-file (spartan-sensor-mesh-configuration-config-file config))
    (validate-config-source
     'application-config
     (spartan-sensor-mesh-configuration-application-config config))
    (validate-config-source
     'ui-root (spartan-sensor-mesh-configuration-ui-root config))
    (validate-rest-host
     (spartan-sensor-mesh-configuration-rest-host config))
    (validate-rest-port
     (spartan-sensor-mesh-configuration-rest-port config))
    (when (and (spartan-sensor-mesh-configuration-nut config)
               (not (package? (spartan-sensor-mesh-configuration-nut config))))
      (error "Spartan Sensor Mesh NUT must be a package"
             (spartan-sensor-mesh-configuration-nut config)))
    (validate-account-name 'user user)
    (validate-account-name 'group group)
    (validate-log-file (spartan-sensor-mesh-configuration-log-file config))
    (unless (and (list? requirements) (every symbol? requirements))
      (error "Spartan Sensor Mesh shepherd requirements must be a list of symbols"
             requirements))
    (unless (and (list? environment) (every string? environment))
      (error "Spartan Sensor Mesh environment variables must be a list of strings"
             environment))
    (spartan-sensor-mesh-configuration (inherit config)
                                      (data-directory data))))

(define (spartan-sensor-mesh-accounts config)
  (let ((config (validate-spartan-sensor-mesh-configuration config)))
    (list (user-group (name (spartan-sensor-mesh-configuration-group config))
                      (system? #t))
          (user-account
           (name (spartan-sensor-mesh-configuration-user config))
           (group (spartan-sensor-mesh-configuration-group config))
           (system? #t)
           (home-directory (spartan-sensor-mesh-configuration-data-directory config))
           (shell (file-append shadow "/sbin/nologin"))))))

(define (spartan-sensor-mesh-activation config)
  (let* ((config (validate-spartan-sensor-mesh-configuration config))
         (data (spartan-sensor-mesh-configuration-data-directory config))
         (user (spartan-sensor-mesh-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((account (getpwnam #$user)))
          (unless account
            (error "Spartan Sensor Mesh account does not exist" #$user))
          (mkdir-p #$data)
          (chown #$data (passwd:uid account) (passwd:gid account))
          (chmod #$data #o750)))))

(define (spartan-sensor-mesh-shepherd-services config)
  (let* ((config (validate-spartan-sensor-mesh-configuration config))
         (package (spartan-sensor-mesh-configuration-package config))
         (config-file (spartan-sensor-mesh-configuration-config-file config))
         (application-config
          (spartan-sensor-mesh-configuration-application-config config))
         (ui-root (spartan-sensor-mesh-configuration-ui-root config))
         (rest-host (spartan-sensor-mesh-configuration-rest-host config))
         (rest-port (spartan-sensor-mesh-configuration-rest-port config))
         (nut (spartan-sensor-mesh-configuration-nut config))
         (user (spartan-sensor-mesh-configuration-user config))
         (group (spartan-sensor-mesh-configuration-group config))
         (data (spartan-sensor-mesh-configuration-data-directory config))
         (log (spartan-sensor-mesh-configuration-log-file config))
         (requirements
          (spartan-sensor-mesh-configuration-shepherd-requirement config))
         (environment
          (spartan-sensor-mesh-configuration-environment-variables config)))
    (list
     (shepherd-service
      (documentation "Run the Spartan Sensor Mesh JVM agent.")
      (provision '(spartan-sensor-mesh))
      (requirement (append '(user-processes networking) requirements))
      (start #~(make-forkexec-constructor
                (append
                 (list #$(file-append package "/bin/spartan-sensor-mesh"))
                 #$(if config-file (list config-file) '()))
                #:user #$user
                #:group #$group
                #:directory #$data
                #:environment-variables
                (append
                 (list #$(string-append "HOME=" data))
                 (if #$nut
                     (list (string-append "PATH="
                                          #$(if nut (file-append nut "/bin") #f)
                                          ":"
                                          #$(if nut (file-append nut "/sbin") #f)))
                     '())
                 (if #$rest-host
                     (list (string-append "REST_HOST=" #$rest-host))
                     '())
                 (if #$rest-port
                     (list (string-append "REST_PORT="
                                          (number->string #$rest-port)))
                     '())
                 (if #$ui-root
                     (list (string-append "REST_DATA_PATH=" #$ui-root))
                     (list (string-append "REST_DATA_PATH="
                                          #$(file-append
                                             package
                                             "/share/spartan-sensor-mesh/data"))))
                 (if #$application-config
                     (list (string-append "JAVA_TOOL_OPTIONS=-Dconfig.file="
                                          #$application-config))
                     '())
                 #$environment)
                #:log-file #$log))
      (stop #~(make-kill-destructor))))))

(define spartan-sensor-mesh-service-type
  (service-type
   (name 'spartan-sensor-mesh)
   (extensions
    (list (service-extension shepherd-root-service-type
                             spartan-sensor-mesh-shepherd-services)
          (service-extension activation-service-type
                             spartan-sensor-mesh-activation)
          (service-extension account-service-type
                             spartan-sensor-mesh-accounts)
          (service-extension profile-service-type
                             (lambda (config)
                               (list (spartan-sensor-mesh-configuration-package
                                      config))))))
   (default-value (spartan-sensor-mesh-configuration))
   (description
    "Run the Spartan Sensor Mesh JVM agent with its bundled web interface.")))
