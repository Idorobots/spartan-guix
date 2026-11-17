(use-modules (gnu) (gnu services) (gnu services shepherd) (gnu services networking)
             (guix build utils) (guix gexp) (guix monads) (guix store)
             (ice-9 textual-ports)
             (spartan build moonraker) (spartan services klipper)
             (spartan services moonraker) (srfi srfi-1) (srfi srfi-64))

(test-begin "moonraker")
(define runner (test-runner-current))
(define temporary (mkdtemp "/tmp/spartan-moonraker-XXXXXX"))
(define data (string-append temporary "/data"))
(define state (string-append temporary "/klipper"))
(define (write-text file text)
  (call-with-output-file file (lambda (port) (display text port))))
(define (read-text file)
  (call-with-input-file file get-string-all))

;; Activation order must not matter: the config link can initially dangle.
(initialize-moonraker-state data state (getuid) (getgid))
(test-equal "configuration links to Klipper state even before it exists" state
  (readlink (string-append data "/config")))
(mkdir state)
(write-text (string-append state "/printer.cfg") "calibrated printer\n")
(test-assert "data directories are owned by the service identity and private"
  (every (lambda (suffix)
           (let ((info (stat (string-append data suffix))))
             (and (= (getuid) (stat:uid info))
                  (= (getgid) (stat:gid info))
                  (= #o750 (stat:perms info)))))
         '("" "/logs" "/gcodes" "/database" "/comms")))
(write-text (string-append data "/gcodes/part.gcode") "G28\n")
(write-text (string-append data "/database/state") "saved state\n")
(initialize-moonraker-state data state (getuid) (getgid))
(test-assert "reconfiguration preserves uploads, database and printer calibration"
  (and (string=? "G28\n" (read-text (string-append data "/gcodes/part.gcode")))
       (string=? "saved state\n" (read-text (string-append data "/database/state")))
       (string=? "calibrated printer\n"
                 (read-text (string-append data "/config/printer.cfg")))))
(define other-state (string-append temporary "/other-klipper"))
(initialize-moonraker-state data other-state (getuid) (getgid))
(test-assert "changing printer directory switches the link without removing old data"
  (and (string=? other-state (readlink (string-append data "/config")))
       (file-exists? (string-append state "/printer.cfg"))))
(delete-file (string-append data "/config"))
(mkdir (string-append data "/config"))
(write-text (string-append data "/config/keep.cfg") "keep\n")
(test-error "an unmanaged configuration directory is not replaced" #t
  (initialize-moonraker-state data state (getuid) (getgid)))
(test-equal "unmanaged configuration survives failed activation" "keep\n"
  (read-text (string-append data "/config/keep.cfg")))

(define (extension target)
  (find (lambda (item) (eq? target (service-extension-target item)))
        (service-type-extensions moonraker-service-type)))
(define (shepherd config)
  ((service-extension-compute (extension shepherd-root-service-type)) config))
(define default (moonraker-configuration))
(define services (shepherd default))
(test-equal "one foreground Moonraker process" '((moonraker))
  (map shepherd-service-provision services))
(test-equal "Moonraker starts after Klipper and networking"
  '(user-processes networking klipper)
  (shepherd-service-requirement (car services)))
(test-equal "consumer can add prerequisite services"
  '(user-processes networking klipper sops-secrets)
  (shepherd-service-requirement
   (car (shepherd (moonraker-configuration
                    (shepherd-requirement '(sops-secrets)))))))
(test-assert "service runs as Klipper with its own data directory and HOME"
  (let ((form (gexp->approximate-sexp (shepherd-service-start (car services)))))
    (and (member "klipper" form)
         (member "/var/lib/moonraker" (cadr form))
         (member '(list "HOME=/var/lib/moonraker") form))))
(define custom-file "/etc/moonraker/custom.conf")
(test-assert "custom configuration is passed directly without a writable copy"
  (let ((start (shepherd-service-start
                (car (shepherd (moonraker-configuration
                                 (config-file custom-file)))))))
    (member custom-file (cadr (gexp->approximate-sexp start)))))
(test-equal "normalized data directory is used at startup" "/srv/moonraker"
  (let* ((config (moonraker-configuration
                  (data-directory "//srv//moonraker///")))
         (form (gexp->approximate-sexp
                (shepherd-service-start (car (shepherd config))))))
    (list-ref (cadr form) 3)))
(for-each
 (lambda (path)
   (test-error (format #f "reject invalid data directory ~s" path) #t
     (shepherd (moonraker-configuration (data-directory path)))))
 '(#f "relative" "/" "/var/lib/" "//gnu///store/data/" "/srv/../data"))
(for-each
 (lambda (path)
   (test-error (format #f "reject overlapping printer directory ~s" path) #t
     (shepherd (moonraker-configuration (data-directory "/srv/printer")
                                        (klipper-state-directory path)))))
 '("//srv//printer/" "/srv/printer/config" "/srv"))
(test-error "relative configuration path is rejected" #t
  (shepherd (moonraker-configuration (config-file "moonraker.conf"))))
(test-assert "runtime configuration path need not exist on the build host"
  (shepherd (moonraker-configuration (config-file "/run/secrets/moonraker.conf"))))
(test-assert "default uses Shepherd-compatible declarative configuration"
  (let ((text (read-text (local-file-absolute-file-name %moonraker-default-config))))
    (and (string-contains text "provider: none")
         (string-contains text "validate_service: False")
         (string-contains text "validate_config: False")
         (not (string-contains text "[update_manager")))))
(test-assert "activation and its build helper lower to a derivation"
  (with-store store
    (run-with-store store
      (gexp->derivation "moonraker-activation-test"
                        ((service-extension-compute
                          (extension activation-service-type)) default)))))
(test-assert "startup lowers the package and declarative configuration file"
  (with-store store
    (run-with-store store
      (gexp->derivation "moonraker-start-test"
                        (shepherd-service-start (car services))))))
(test-assert "Moonraker and Klipper integrate with base Guix System services"
  (let* ((os (operating-system
              (host-name "moonraker-test") (timezone "Etc/UTC") (locale "en_US.utf8")
              (bootloader (bootloader-configuration
                           (bootloader grub-bootloader) (targets '("/dev/sda"))))
              (file-systems (cons (file-system
                                   (device "/dev/sda1") (mount-point "/")
                                   (type "ext4"))
                                 %base-file-systems))
              (services (append
                         (list (service klipper-service-type
                                        (klipper-configuration
                                         (config-file (plain-file "printer.cfg" ""))))
                               (service moonraker-service-type)
                               (service dhcpcd-service-type))
                         %base-services))))
         (services (shepherd-configuration-services
                    (service-value
                     (fold-services (operating-system-services os)
                                    #:target-type shepherd-root-service-type)))))
    (assert-valid-graph services)
    (any (lambda (item) (memq 'moonraker (shepherd-service-provision item))) services)))

(delete-file-recursively temporary)
(test-end "moonraker")
(exit (zero? (test-runner-fail-count runner)))
