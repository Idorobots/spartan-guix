(use-modules (spartan packages mixed))
;; Exercise source-build fallbacks independently of local/substitute availability.
((@@ (spartan packages mixed) %native-outputs-available?) (const #f))
(use-modules (gnu)
             (gnu image)
             (gnu packages base)
             (gnu services shepherd)
             (gnu system image)
             (gnu system images raspberrypi)
             (gnu system nss)
             (gnu system shadow)
             (guix build-system)
             (guix gexp)
             (guix packages)
             (spartan packages firmware)
             (spartan packages klipper)
             (spartan packages moonraker)
             (spartan services klipper)
             (spartan services moonraker)
             (spartan system build-policy)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "policy-services")

(define custom-essential-service-type
  (service-type (name 'policy-test-essential) (extensions '())
                (description "Essential-service preservation fixture.")))

(define (configured base name)
  (with-build-policy
   (operating-system
     (inherit base)
     (host-name name)
     (name-service-switch %mdns-host-lookup-nss)
     (sudoers-file (plain-file "policy-sudoers" "root ALL=(ALL) ALL\n"))
     (packages (cons* hello klipper moonraker (operating-system-packages base)))
     (users (cons (user-account (name "policy-user") (group "users"))
                  (operating-system-users base)))
     (essential-services
      (cons (service custom-essential-service-type 'preserved) essential-services))
     (services
      (cons* (service klipper-service-type
                      (klipper-configuration
                       (config-files (list (cons "printer.cfg"
                                                 (plain-file "printer.cfg" ""))))))
             (service moonraker-service-type (moonraker-configuration))
             (operating-system-user-services base))))
   (operating-system-build-policy base)))

(define systems
  (map configured (list rpi2-barebones-os rpi4-barebones-os rpi3-barebones-os)
       '("policy-armhf" "policy-aarch64" "policy-a53")))

(define (essential os type)
  (find (lambda (s) (eq? type (service-kind s)))
        (operating-system-essential-services os)))

(define (folded os type)
  (service-value (fold-services (operating-system-services os)
                               #:target-type type)))

(for-each
 (lambda (os img system target)
   (for-each
    (lambda (os phase)
      (define (label text)
        (string-append (operating-system-host-name os) " " phase ": " text))
      (test-assert (label "firmware activation uses the selected OS packages")
        (equal? (operating-system-firmware os) (folded os firmware-service-type)))
      (test-assert (label "firmware fallback builds on x86 for the OS target")
        (let ((bag (package->bag (car (folded os firmware-service-type))
                                 system #f #:graft? #f)))
          (and (string=? "x86_64-linux" (bag-system bag))
               (equal? target (bag-target bag)))))
      (test-assert (label "kernel service uses the selected kernel and modules")
        (let ((config (folded os linux-builder-service-type)))
          (and (eq? (operating-system-kernel os)
                    (linux-builder-configuration-kernel config))
               (equal? (operating-system-kernel-loadable-modules os)
                       (linux-builder-configuration-modules config)))))
      (test-assert (label "the system profile includes every selected OS package")
        (let ((profile (folded os profile-service-type)))
          (every (lambda (p) (memq p profile)) (operating-system-packages os))))
      (test-equal (label "hostname activation uses the commissioned name")
        (operating-system-host-name os) (folded os host-name-service-type))
      (test-assert (label "account activation includes every configured user and group")
        (let ((accounts (folded os account-service-type)))
          (every (lambda (account) (memq account accounts))
                 (append (operating-system-users os) (operating-system-groups os)))))
      (test-equal (label "/etc uses the host's name-service switch")
        (name-service-switch->string (operating-system-name-service-switch os))
        (plain-file-content
         (cadr (assoc "nsswitch.conf"
                      (service-value (essential os etc-service-type))))))
      (test-assert (label "/etc validates the host's sudoers file")
        (let ((sudoers (cadr (assoc "sudoers"
                                   (service-value (essential os etc-service-type))))))
          (any (lambda (input)
                 (eq? (operating-system-sudoers-file os) (gexp-input-thing input)))
               ((@@ (guix gexp) gexp-inputs) (computed-file-gexp sudoers)))))
      (test-assert (label "Shepherd retains the policy-selected package")
        (let* ((config (service-value (essential os shepherd-root-service-type)))
               (p (shepherd-configuration-shepherd config)))
          (eq? p (build-policy-package (operating-system-build-policy os) p))))
      (test-equal (label "custom essential services survive policy application")
        'preserved (folded os custom-essential-service-type))
      (test-assert (label "Klipper and Moonraker profile extensions use the selected recipes")
        (every
         (lambda (entry)
           (let ((config
                  (service-value
                   (find (lambda (s) (eq? (car entry) (service-kind s)))
                         (operating-system-user-services os)))))
             (memq ((cdr entry) config) (operating-system-packages os))))
         (list (cons klipper-service-type klipper-configuration-package)
               (cons moonraker-service-type moonraker-configuration-package)))))
    (list os (operating-system-for-image img)) '("host" "image"))
   ;; Essential services must remain thunked over the final OS, including later
   ;; inheritance and the initrd replacement performed by image conversion.
   (let* ((initrd (plain-file "essential-services-initrd" "fixture"))
          (extra (package (inherit hello) (name "policy-inherited-profile")))
          (probe (operating-system
                   (inherit os)
                   (host-name "essential-services-probe")
                   (packages (cons extra (operating-system-packages os)))
                   (initrd (lambda _ initrd)))))
     (test-equal (string-append system ": inherited hostname is recomputed")
       "essential-services-probe" (folded probe host-name-service-type))
     (test-assert (string-append system ": inherited profile is recomputed")
       (memq extra (folded probe profile-service-type)))
     (test-assert (string-append system ": inherited initrd is recomputed")
       (eq? initrd (cadr (assoc "initrd"
                               (service-value (essential probe system-service-type))))))))
 systems
 (map (lambda (os type) (os->image os #:type type)) systems
      (list rpi2-image-type rpi4-image-type rpi-image-type))
 '("armhf-linux" "aarch64-linux" "aarch64-linux")
 '("arm-linux-gnueabihf" "aarch64-linux-gnu" "aarch64-linux-gnu"))

(test-assert "available native firmware is retained by the actual firmware service"
  (let* ((base (package (inherit linux-firmware-uncompressed)
                 (name "policy-firmware-native-hit")))
         (policy (make-raspberry-pi-build-policy #:mixed-packages (list base))))
    (parameterize (((@@ (spartan packages mixed) %native-outputs-available?)
                    (lambda (p candidate system) (eq? p base))))
      (let* ((os (with-build-policy
                  (operating-system (inherit rpi4-barebones-os)
                    (firmware (list base)))
                  policy))
             (bag (package->bag (car (folded os firmware-service-type))
                                "aarch64-linux" #f #:graft? #f)))
        (and (string=? "aarch64-linux" (bag-system bag))
             (not (bag-target bag)))))))

(define runner (test-runner-current))
(test-end "policy-services")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
