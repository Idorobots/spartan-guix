(use-modules (gnu) (gnu services) (gnu services shepherd) (guix build utils)
             (guix gexp) (guix monads) (guix store) (ice-9 textual-ports)
             (spartan build klipper) (spartan services klipper)
             (srfi srfi-1) (srfi srfi-64))

(test-begin "klipper")
(define runner (test-runner-current))
(define test-dir (mkdtemp "/tmp/spartan-klipper-XXXXXX"))
(define state (string-append test-dir "/state"))
(define run (string-append test-dir "/run"))
(define seed (string-append test-dir "/seed.cfg"))
(define config-file (string-append state "/printer.cfg"))
(define (write-text path text)
  (call-with-output-file path (lambda (port) (display text port))))
(define (read-text path)
  (call-with-input-file path get-string-all))

(write-text seed "initial configuration\n")
(define seeds (list (cons "printer.cfg" seed)))
(initialize-klipper-state state run seeds (getuid) (getgid))
(test-equal "initial configuration is copied" "initial configuration\n"
  (read-text config-file))
(test-equal "configuration is writable by its owner" #o640
  (logand #o777 (stat:mode (stat config-file))))
(write-text config-file "calibrated configuration\n")
(write-text seed "updated seed\n")
(initialize-klipper-state state run seeds (getuid) (getgid))
(test-equal "subsequent activation preserves calibration" "calibrated configuration\n"
  (read-text config-file))
(define workspace (string-append run "/firmware"))
(test-assert "firmware workspace is not created by default"
  (not (file-exists? workspace)))

;; Model the immutable installed source, including an executable flashing tool
;; and a symlink whose target must not have its permissions changed.
(define firmware-source (string-append test-dir "/source"))
(mkdir-p (string-append firmware-source "/scripts"))
(write-text (string-append firmware-source "/Makefile") "firmware build\n")
(write-text (string-append firmware-source "/scripts/flash.sh") "#!/bin/sh\n")
(chmod (string-append firmware-source "/Makefile") #o444)
(chmod (string-append firmware-source "/scripts/flash.sh") #o555)
(symlink (string-append firmware-source "/Makefile")
         (string-append firmware-source "/source-link"))
(initialize-klipper-state state run seeds (getuid) (getgid)
                          #:firmware-source firmware-source)
(test-assert "firmware copy is writable, owned correctly and retains executable tools"
  (let ((makefile (stat (string-append workspace "/Makefile")))
        (script (stat (string-append workspace "/scripts/flash.sh"))))
    (and (string=? "firmware build\n" (read-text (string-append workspace "/Makefile")))
         (= (getuid) (stat:uid makefile))
         (= (getgid) (stat:gid makefile))
         (= #o200 (logand #o200 (stat:perms makefile)))
         (= #o300 (logand #o300 (stat:perms script)))
         (= #o750 (stat:perms (stat workspace)))
         (eq? 'symlink (stat:type (lstat (string-append workspace "/source-link"))))
         (= #o444 (stat:perms (stat (string-append firmware-source "/Makefile")))))))
(write-text (string-append workspace "/.config") "board settings\n")
(mkdir (string-append workspace "/out"))
(write-text (string-append workspace "/out/klipper.bin") "built firmware\n")
(write-text (string-append firmware-source "/new-source") "new package\n")
(initialize-klipper-state state run seeds (getuid) (getgid)
                          #:firmware-source firmware-source)
(test-assert "reconfiguration preserves the current firmware build without merging source"
  (and (string=? "board settings\n" (read-text (string-append workspace "/.config")))
       (string=? "built firmware\n" (read-text (string-append workspace "/out/klipper.bin")))
       (not (file-exists? (string-append workspace "/new-source")))))
(delete-file-recursively run)
(initialize-klipper-state state run seeds (getuid) (getgid)
                          #:firmware-source firmware-source)
(test-assert "a cleared runtime directory gets fresh source while printer calibration persists"
  (and (file-exists? (string-append workspace "/new-source"))
       (not (file-exists? (string-append workspace "/.config")))
       (not (file-exists? (string-append workspace "/out")))
       (string=? "calibrated configuration\n" (read-text config-file))))

(define outside (string-append test-dir "/outside"))
(mkdir outside)
(symlink outside (string-append state "/linked"))
(test-error "a symlink parent cannot redirect fragment creation" #t
  (initialize-klipper-state state run (list (cons "linked/fragment.cfg" seed))
                            (getuid) (getgid)))
(test-assert "no fragment is written through a symlink"
  (not (file-exists? (string-append outside "/fragment.cfg"))))
(symlink (string-append outside "/missing.cfg") (string-append state "/dangling.cfg"))
(test-error "a dangling destination link cannot redirect fragment creation" #t
  (initialize-klipper-state state run (list (cons "dangling.cfg" seed)) (getuid) (getgid)))
(test-assert "no config is written through a dangling link"
  (not (file-exists? (string-append outside "/missing.cfg"))))

(define printer-seed (plain-file "printer.cfg" "[printer]\n"))
(define printer-entry (cons "printer.cfg" printer-seed))
(define config (klipper-configuration (config-files (list printer-entry))))
(define firmware-config
  (klipper-configuration (inherit config) (firmware-workspace? #t)))
(test-assert "firmware workspace is opt-in"
  (and (not (klipper-configuration-firmware-workspace? config))
       (klipper-configuration-firmware-workspace? firmware-config)))
(define (extension target)
  (find (lambda (item) (eq? target (service-extension-target item)))
        (service-type-extensions klipper-service-type)))
(define shepherd
  ((service-extension-compute (extension shepherd-root-service-type)) config))
(test-equal "one Klipper process" '((klipper))
  (map shepherd-service-provision shepherd))
(test-assert "service uses writable configuration, socket and dialout"
  (let ((form (gexp->approximate-sexp (shepherd-service-start (car shepherd)))))
    (and (member "/var/lib/klipper/printer.cfg" (cadr form))
         (member "/run/klipper/klippy.sock" (cadr form))
         (member ''("dialout") form))))
(test-error "reject store-backed writable state" #t
  ((service-extension-compute (extension activation-service-type))
   (klipper-configuration (inherit config)
                           (state-directory "/gnu/store/printer"))))
(for-each
 (lambda (files)
   (test-error "reject invalid or conflicting config-files entries" #t
     ((service-extension-compute (extension activation-service-type))
      (klipper-configuration (config-files files)))))
 (cons* '() printer-seed (list printer-seed)
        (list (cons "frag.cfg" printer-seed))
        (list printer-entry (list "frag.cfg" printer-seed))
        (list printer-entry (cons "config.d/a.cfg" printer-seed)
              (cons "config.d/a.cfg" printer-seed))
        (list printer-entry (cons "config.d/a.cfg" printer-seed)
              (cons "config.d" printer-seed))
        (map (lambda (path) (list printer-entry (cons path printer-seed)))
             '("" "/abs.cfg" "config.d/../escape.cfg" "config.d//frag.cfg"
               "printer.cfg" "printer.cfg/frag.cfg" "klippy.log"))))
(define (activation-error config)
  (catch 'misc-error
    (lambda ()
      ((service-extension-compute (extension activation-service-type)) config)
      #f)
    (lambda (key subr message arguments . rest)
      (apply format #f message arguments))))
(for-each
 (lambda (case)
   (test-assert (car case)
     (let ((message (activation-error
                     (klipper-configuration
                      (inherit config)
                      (state-directory (cadr case))
                      (run-directory (caddr case))))))
       (and message (string-contains message (cadddr case))))))
 '(("relative state directory reports its field"
    "relative" "/run/klipper" "state-directory")
   ("non-string run directory reports its field"
    "/var/lib/klipper" #f "run-directory")
   ("normalized store path is rejected"
    "//gnu///store/printer/" "/run/klipper" "state-directory")
   ("normalized shared directory is rejected"
    "/var/lib/klipper" "//run///" "run-directory")
   ("dot components are rejected"
    "/var/./lib/klipper" "/run/klipper" "state-directory")
   ("parent components are rejected"
    "/var/lib/klipper" "/run/other/../klipper" "run-directory")
   ("trailing slashes cannot disguise identical directories"
    "/srv/klipper" "/srv/klipper/" "must be distinct")
   ("repeated slashes cannot disguise identical directories"
    "/srv//klipper" "//srv/klipper///" "must be distinct")))
(for-each
 (lambda (value)
   (test-assert (format #f "firmware-workspace? rejects non-boolean ~s" value)
     (let ((message (activation-error
                     (klipper-configuration
                      (inherit config) (firmware-workspace? value)))))
       (and message (string-contains message "firmware-workspace?")))))
 '("yes" 1 ()))
(define normalized-config
  (klipper-configuration
   (inherit firmware-config)
   (state-directory "/srv//klipper///")
   (run-directory "//run//klipper///")))
(test-assert "Shepherd uses normalized paths"
  (let* ((services ((service-extension-compute (extension shepherd-root-service-type))
                    normalized-config))
         (form (gexp->approximate-sexp (shepherd-service-start (car services)))))
    (and (member "/srv/klipper/printer.cfg" (cadr form))
         (member "/run/klipper/klippy.sock" (cadr form)))))
(test-error "Shepherd also validates firmware-workspace?" #t
  ((service-extension-compute (extension shepherd-root-service-type))
   (klipper-configuration (inherit config) (firmware-workspace? "yes"))))
(test-assert "activation code and its seed lower to a derivation"
  (with-store store
    (run-with-store store
      (gexp->derivation "klipper-activation-test"
                        ((service-extension-compute
                          (extension activation-service-type)) config)))))
(test-assert "activation with firmware workspace lowers to a derivation"
  (with-store store
    (run-with-store store
      (gexp->derivation "klipper-firmware-activation-test"
                        ((service-extension-compute
                          (extension activation-service-type)) firmware-config)))))
(test-assert "service integrates with base Guix System services"
  (let* ((os (operating-system
              (host-name "klipper-test") (timezone "Etc/UTC") (locale "en_US.utf8")
              (bootloader (bootloader-configuration
                           (bootloader grub-bootloader) (targets '("/dev/sda"))))
              (file-systems (cons (file-system
                                   (device "/dev/sda1") (mount-point "/")
                                   (type "ext4"))
                                  %base-file-systems))
              (services (cons (service klipper-service-type firmware-config)
                              %base-services))))
         (services (shepherd-configuration-services
                    (service-value
                     (fold-services (operating-system-services os)
                                    #:target-type shepherd-root-service-type)))))
    (assert-valid-graph services)
    (any (lambda (item) (memq 'klipper (shepherd-service-provision item)))
         services)))
(system* "rm" "-rf" test-dir)
(test-end "klipper")
(exit (zero? (test-runner-fail-count runner)))
