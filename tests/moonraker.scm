(use-modules (gnu) (gnu services) (gnu services shepherd) (gnu services networking)
             (guix build utils) (guix derivations) (guix gexp) (guix monads) (guix store)
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
(define (realize file)
  (with-store store
    (let ((drv (run-with-store store
                 (gexp->derivation "moonraker-test-reference"
                   #~(call-with-output-file #$output
                       (lambda (port) (display #$file port)))))))
      (build-derivations store (list drv))
      (read-text (derivation->output-path drv)))))

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
(test-equal "Moonraker starts independently of Klipper"
  '(user-processes networking)
  (shepherd-service-requirement (car services)))
(test-equal "consumer can add prerequisite services"
  '(user-processes networking sops-secrets)
  (shepherd-service-requirement
   (car (shepherd (moonraker-configuration
                    (shepherd-requirement '(sops-secrets)))))))
(test-assert "service runs as Klipper with its own data directory and HOME"
  (let ((form (gexp->approximate-sexp (shepherd-service-start (car services)))))
    (and (member "klipper" form)
         (member "/var/lib/moonraker" (cadr form))
         (member '(list "HOME=/var/lib/moonraker") form))))
(define custom-file "/etc/moonraker/custom.conf")
(test-assert "named configuration tree preserves nested paths and runtime targets"
  (let* ((base (plain-file "base.conf" "[include conf.d/custom.conf]\n"))
         (config (moonraker-configuration
                  (config-files (list (cons "conf.d/custom.conf" custom-file)
                                      (cons "moonraker.conf" base)))))
         (wrapper (realize (moonraker-config-file config)))
         (tree (string-append (dirname wrapper) "/config")))
    (and (string-prefix? "[include config/moonraker.conf]\n\n[machine]\n"
                         (read-text wrapper))
         (string=? (plain-file-content base) (read-text (string-append tree "/moonraker.conf")))
         (string=? custom-file (readlink (string-append tree "/conf.d/custom.conf"))))))
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
(for-each
 (lambda (files)
   (test-error "reject non-list, empty or unsafe configuration files" #t
     (shepherd (moonraker-configuration (config-files files)))))
 '("/etc/moonraker.conf" () ("moonraker.conf") (("extra.conf" . "/etc/extra.conf"))
   (("moonraker.conf" . "relative.conf")) (("moonraker.conf" . #f))
   (("moonraker.conf" . "/etc/a.conf") ("../escape.conf" . "/etc/b.conf"))
   (("moonraker.conf" . "/etc/a.conf") ("moonraker.conf" . "/etc/b.conf"))))
(test-assert "runtime configuration path need not exist on the build host"
   (shepherd (moonraker-configuration
              (config-files '(("moonraker.conf" . "/run/secrets/moonraker.conf"))))))
(test-assert "generated configuration selects Shepherd with canonical policy and helper"
  (let ((text (read-text (realize (moonraker-config-file default)))))
    (and (string-contains text "provider: shepherd")
         (string-contains text "validate_service: False")
         (string-contains text "validate_config: False")
         (string-contains text (string-append "shepherd_policy: "
                                             (realize (moonraker-shepherd-policy default))))
         (string-contains text "-moonraker-provider-shepherd-0.1.0/bin/moonraker-shepherd")
         (not (string-contains text "[update_manager")))))
(define restricted
  (moonraker-configuration
   (managed-services '(("klipper" start stop restart) ("moonraker" restart) ("camera")))
   (power-actions '())))
(test-equal "policy carries status-only services and independently disabled power"
  '((version . 1) (socket . "/var/run/shepherd/socket") (moonraker-service . "moonraker")
    (services . (("klipper" start stop restart) ("moonraker" restart) ("camera"))) (power))
  (call-with-input-file (realize (moonraker-shepherd-policy restricted)) read))
(define host-sudoers (plain-file "host-sudoers" "root ALL=(ALL) ALL\n%operators ALL=(ALL) ALL\n"))
(define combined-sudoers (realize (moonraker-sudoers-file restricted host-sudoers)))
(define includes
  (map (lambda (line) (substring line (string-length "@include ")))
       (remove string-null? (string-split (read-text combined-sudoers) #\newline))))
(test-equal "sudoers preserves the host's original specification via include"
  (realize host-sudoers) (car includes))
(test-equal "sudoers grants exactly the policy's commands, including status diagnostics"
  '("capabilities" "status" "start klipper" "stop klipper" "restart klipper" "restart moonraker")
  (let ((prefix (string-append
                 "klipper ALL=(root) NOPASSWD: NOSETENV: "
                 (realize (file-append (@ (spartan packages moonraker-provider-shepherd)
                                         moonraker-provider-shepherd)
                                      "/bin/moonraker-shepherd"))
                 " " (realize (moonraker-shepherd-policy restricted)) " ")))
    (map (lambda (line)
           (and (string-prefix? prefix line) (substring line (string-length prefix))))
         (remove string-null? (string-split (read-text (cadr includes)) #\newline)))))
(test-assert "composed sudoers passes Guix's recursive visudo check"
  (zero? (system* (realize (file-append (@ (gnu packages admin) sudo) "/sbin/visudo"))
                  "--check" "--file" combined-sudoers)))
(for-each
 (lambda (services)
   (test-error (format #f "reject unsafe managed services ~s" services) #t
     (moonraker-sudoers-file (moonraker-configuration (managed-services services)))))
 '((("moonraker" stop)) (("moonraker" restart) ("root" restart))
   (("moonraker" restart) ("x *" start)) (("moonraker" restart) ("x" bogus))
   (("moonraker" restart) ("x" start start)) (("moonraker" restart) ("moonraker" restart))
   (("klipper" start))))
(for-each
 (lambda (actions)
   (test-error (format #f "reject invalid power permissions ~s" actions) #t
     (moonraker-shepherd-policy (moonraker-configuration (power-actions actions)))))
 '((poweroff poweroff) (eval) #f))
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
              (sudoers-file (moonraker-sudoers-file default host-sudoers))
              (services (append
                         (list (service klipper-service-type
                                        (klipper-configuration
                                          (config-files (list (cons "printer.cfg"
                                                                    (plain-file "seed.cfg" ""))))))
                               (service moonraker-service-type)
                               (service dhcpcd-service-type))
                         %base-services))))
         (services (shepherd-configuration-services
                    (service-value
                     (fold-services (operating-system-services os)
                                    #:target-type shepherd-root-service-type)))))
    (assert-valid-graph services)
    (any (lambda (item) (memq 'moonraker (shepherd-service-provision item))) services)))

(define runtime-directory (string-append temporary "/runtime"))
(mkdir runtime-directory #o700)
(define runtime-config
  (moonraker-configuration
    (config-files
     (list (cons "parts/override.conf" (string-append runtime-directory "/override.conf"))
           (cons "moonraker.conf" (string-append runtime-directory "/application.conf"))
           (cons "parts/authorization.conf"
                 (plain-file "auth.conf" "[authorization]\ntrusted_clients: 127.0.0.1/32\n"))))
   (shepherd-socket (string-append runtime-directory "/socket"))
   (power-actions '())))
(test-assert "installed Moonraker and helper manage private Shepherd using generated configuration"
  (zero? (system*
          (realize (file-append (@ (gnu packages python) python) "/bin/python3"))
          (string-append (dirname (current-filename)) "/moonraker-shepherd-runtime.py")
          runtime-directory
          (realize (@ (spartan packages moonraker) moonraker))
          (realize (@ (spartan packages moonraker-provider-shepherd) moonraker-provider-shepherd))
          (realize (@ (gnu packages admin) shepherd))
          (realize (moonraker-config-file runtime-config))
          (realize (moonraker-shepherd-policy runtime-config))
          (realize (file-append (@ (gnu packages base) coreutils) "/bin/sleep")))))

(delete-file-recursively temporary)
(test-end "moonraker")
(exit (zero? (test-runner-fail-count runner)))
