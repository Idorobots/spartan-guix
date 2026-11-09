(define-module (spartan services nut)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system shadow)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (spartan packages nut)
  #:use-module (srfi srfi-1)
  #:export (nut-ups nut-ups? nut-ups-name nut-ups-driver nut-ups-port
            nut-ups-extra-config
            upsd-configuration upsd-configuration? upsd-configuration-package
            upsd-configuration-ups upsd-configuration-extra-config
            upsd-configuration-users-file
            upsd-configuration-shepherd-requirement upsd-service-type))

(define-record-type* <nut-ups> nut-ups make-nut-ups nut-ups?
  (name nut-ups-name)
  (driver nut-ups-driver)
  (port nut-ups-port (default "auto"))
  (extra-config nut-ups-extra-config (default "")))

(define-record-type* <upsd-configuration>
  upsd-configuration make-upsd-configuration upsd-configuration?
  (package upsd-configuration-package (default nut))
  (ups upsd-configuration-ups (default '()))
  (extra-config upsd-configuration-extra-config
                (default "LISTEN 127.0.0.1 3493\n"))
  ;; The consumer supplies this file and makes it readable by nut at runtime.
  (users-file upsd-configuration-users-file (default #f))
  (shepherd-requirement upsd-configuration-shepherd-requirement (default '())))

(define (validated-ups config)
  (let ((devices (upsd-configuration-ups config)))
    (define (identifier? value)
      (and (string? value) (positive? (string-length value))
           (every (lambda (c) (or (char-alphabetic? c) (char-numeric? c)
                                 (memv c '(#\- #\_ #\.))))
                  (string->list value))
           (not (member value '("." "..")))))
    (unless (and (pair? devices)
                 (every (lambda (ups)
                          (and (identifier? (nut-ups-name ups))
                               (identifier? (nut-ups-driver ups))
                               (not (string-index (nut-ups-port ups) #\newline))
                               (not (string-index (nut-ups-port ups) #\"))))
                        devices)
                 (= (length devices)
                    (length (delete-duplicates (map nut-ups-name devices)))))
      (error "NUT requires uniquely named UPS devices and valid driver names"))
    devices))

(define (ups-file config)
  (plain-file "ups.conf"
              (string-append
               "statepath = /run/nut\n"
               (string-concatenate
                (map (lambda (ups)
                       (string-append "[" (nut-ups-name ups) "]\n"
                                      "driver = " (nut-ups-driver ups) "\n"
                                      "port = \"" (nut-ups-port ups) "\"\n"
                                      (nut-ups-extra-config ups) "\n"))
                     (validated-ups config))))))

(define (upsd-etc config)
  ;; The outer /etc union checks that each source exists at build time.  Put
  ;; the optional runtime link inside a directory that is built in the store,
  ;; permitting that link to remain dangling until the consumer creates it.
  (let ((users (upsd-configuration-users-file config)))
    (when (and users (not (and (string? users) (string-prefix? "/" users))))
      (error "upsd users-file must be an absolute file path" users))
    `(("nut" ,(file-union
               "nut-config"
               `(("ups.conf" ,(ups-file config))
                 ("upsd.conf" ,(plain-file "upsd.conf"
                                          (upsd-configuration-extra-config config)))
                 ("upsd.users" ,(or users (plain-file "upsd.users" ""))))
               #:dangling-symlinks? (and users #t))))))

(define (upsd-activation _)
  #~(begin
      (use-modules (guix build utils))
      (let ((account (getpwnam "nut")))
        (mkdir-p "/run/nut")
        (chown "/run/nut" (passwd:uid account) (passwd:gid account))
        (chmod "/run/nut" #o750))))

(define (upsd-shepherd-services config)
  (let* ((package (upsd-configuration-package config))
         (devices (validated-ups config))
         (driver-provision (lambda (ups)
                      (string->symbol (string-append "nut-driver-" (nut-ups-name ups))))))
    (cons
     (shepherd-service
      (documentation "Serve UPS status over the NUT protocol.")
      (provision '(upsd))
      (requirement (append '(networking)
                           (map driver-provision devices)
                           (upsd-configuration-shepherd-requirement config)))
      (start #~(make-forkexec-constructor
                (list #$(file-append package "/sbin/upsd") "-F")
                #:user "nut" #:group "nut"
                #:environment-variables '("NUT_CONFPATH=/etc/nut")
                #:log-file "/var/log/upsd.log"))
      (stop #~(make-kill-destructor)))
     (map (lambda (ups)
            (shepherd-service
             (documentation (string-append "Run the NUT driver for " (nut-ups-name ups) "."))
             (provision (list (driver-provision ups)))
             (requirement '(user-processes udev networking))
             (start #~(make-forkexec-constructor
                       (list #$(file-append package "/libexec/nut/" (nut-ups-driver ups))
                             "-F" "-a" #$(nut-ups-name ups))
                       #:user "nut" #:group "nut"
                       #:environment-variables '("NUT_CONFPATH=/etc/nut")
                       #:log-file #$(string-append "/var/log/nut-" (nut-ups-name ups) ".log")))
             (stop #~(make-kill-destructor))))
          devices))))

(define upsd-service-type
  (service-type
   (name 'upsd)
   (extensions
    (list
     (service-extension shepherd-root-service-type upsd-shepherd-services)
     (service-extension etc-service-type upsd-etc)
     (service-extension activation-service-type upsd-activation)
     (service-extension account-service-type
                        (const (list (user-group (name "nut") (system? #t))
                                     (user-account
                                      (name "nut") (group "nut") (system? #t)
                                      (home-directory "/var/empty")
                                      (shell (file-append
                                              (@ (gnu packages admin) shadow)
                                              "/sbin/nologin"))))))
     (service-extension udev-service-type
                        (lambda (config) (list (upsd-configuration-package config))))
     (service-extension profile-service-type
                        (lambda (config) (list (upsd-configuration-package config))))))
   (description "Run explicitly configured NUT UPS drivers and the upsd server.")))
