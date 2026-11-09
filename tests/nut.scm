(use-modules (gnu) (gnu services) (gnu services shepherd) (gnu services networking)
             (guix gexp) (spartan services nut) (srfi srfi-1) (srfi srfi-64))

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
(test-error "duplicate device names rejected" #t
  (shepherd (config (list first-ups first-ups))))
(test-error "driver path traversal rejected" #t
  (shepherd (config (list (nut-ups (name "bad") (driver "../upsd"))))))
(test-error "empty device list rejected" #t
  (shepherd (config '())))
(test-error "relative credentials path rejected" #t
  ((@@ (spartan services nut) upsd-activation)
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
