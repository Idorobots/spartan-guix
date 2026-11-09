(use-modules (gnu) (gnu services) (gnu services shepherd) (gnu services networking)
             (guix derivations) (guix gexp) (guix monads) (guix store)
             (ice-9 textual-ports)
             (spartan services nut) (srfi srfi-1) (srfi srfi-64))

(test-begin "nut")
(define runner (test-runner-current))
(define (shepherd config)
  ((service-extension-compute
    (car (service-type-extensions upsd-service-type))) config))
(define (config devices)
  (upsd-configuration (ups devices)))
(define first-ups
  (nut-ups (name "office") (driver "usbhid-ups")))
(define second-ups
  (nut-ups (name "rack") (driver "snmp-ups") (port "192.0.2.10")))
(define services (shepherd (config (list first-ups second-ups))))
(test-equal "only declared drivers are started"
  '((upsd) (nut-driver-office) (nut-driver-rack))
  (map shepherd-service-provision services))
(test-equal "server depends on both drivers"
  '(networking nut-driver-office nut-driver-rack)
  (shepherd-service-requirement (car services)))
(test-equal "consumer can order upsd after an external file provider"
  '(networking nut-driver-office sops-secrets)
  (shepherd-service-requirement
   (car (shepherd (upsd-configuration
                    (ups (list first-ups))
                    (shepherd-requirement '(sops-secrets)))))))
(test-error "duplicate device names rejected" #t
  (shepherd (config (list first-ups first-ups))))
(test-error "driver path traversal rejected" #t
  (shepherd (config (list (nut-ups (name "bad") (driver "../upsd"))))))
(test-error "empty device list rejected" #t
  (shepherd (config '())))
(test-error "relative credentials path rejected" #t
  ((@@ (spartan services nut) upsd-etc)
   (upsd-configuration (ups (list first-ups)) (users-file "secret"))))
(test-assert "configuration includes only declared devices"
  (let ((text (plain-file-content
               ((@@ (spartan services nut) ups-file)
                (config (list first-ups second-ups))))))
    (and (string-contains text "[office]\ndriver = usbhid-ups\nport = \"auto\"")
         (string-contains text "[rack]\ndriver = snmp-ups\nport = \"192.0.2.10\""))))
(test-assert "all services run in foreground and as nut"
  (every (lambda (service)
           (let ((form (gexp->approximate-sexp (shepherd-service-start service))))
             (and (member "nut" form)
                  (member "-F" (cdr (cadr form))))))
         services))

;; Build the actual /etc union, not just the service graph.  Guix validates
;; sources here, before the target host's activation can create runtime files.
(define (build-etc config)
  (let* ((extension (find (lambda (extension)
                           (eq? (service-extension-target extension)
                                etc-service-type))
                         (service-type-extensions upsd-service-type)))
         (entries ((service-extension-compute extension) config)))
    (with-store store
      (let ((drv (run-with-store store
                   (lower-object (file-union "nut-test-etc" entries)))))
        (build-derivations store (list drv))
        (derivation->output-path drv)))))

(define default-etc (build-etc (config (list first-ups))))
(test-equal "default users file is built empty without runtime provisioning"
  ""
  (call-with-input-file (string-append default-etc "/nut/upsd.users")
    get-string-all))
(test-assert "default configuration includes public UPS and listener settings"
  (and (string-contains
        (call-with-input-file (string-append default-etc "/nut/ups.conf")
          get-string-all)
        "[office]\ndriver = usbhid-ups\n")
       (string=?
        (call-with-input-file (string-append default-etc "/nut/upsd.conf")
          get-string-all)
        "LISTEN 127.0.0.1 3493\n")))

(define private-etc
  (build-etc (upsd-configuration
              (ups (list first-ups))
              (users-file "/run/secrets/nut-test.users"))))
(test-equal "runtime credentials link survives building the outer /etc union"
  "/run/secrets/nut-test.users"
  (readlink (string-append private-etc "/nut/upsd.users")))
(test-assert "runtime credentials configuration still includes public files"
  (every (lambda (file)
           (file-exists? (string-append private-etc "/nut/" file)))
         '("ups.conf" "upsd.conf")))
(test-equal "activation does not depend on or provision the consumer's users file"
  (gexp->approximate-sexp
   ((@@ (spartan services nut) upsd-activation) (config (list first-ups))))
  (gexp->approximate-sexp
   ((@@ (spartan services nut) upsd-activation)
    (upsd-configuration
     (ups (list first-ups))
     (users-file "/run/secrets/nut-test.users")))))

(test-assert "service integrates with base Guix System services"
  (let* ((os (operating-system
              (host-name "nut-test") (timezone "Etc/UTC") (locale "en_US.utf8")
              (bootloader (bootloader-configuration
                           (bootloader grub-bootloader) (targets '("/dev/sda"))))
              (file-systems (cons (file-system
                                   (device "/dev/sda1") (mount-point "/")
                                   (type "ext4"))
                                  %base-file-systems))
              (services (cons* (service dhcpcd-service-type)
                               (service upsd-service-type
                                       (config (list first-ups)))
                              %base-services))))
         (services (shepherd-configuration-services
                    (service-value
                     (fold-services (operating-system-services os)
                                    #:target-type shepherd-root-service-type)))))
    (assert-valid-graph services)
    (any (lambda (service) (memq 'upsd (shepherd-service-provision service)))
         services)))
(test-end "nut")
(exit (zero? (test-runner-fail-count runner)))
