(use-modules (gnu services)
             (guix build utils)
             (guix derivations)
             (guix monads)
             (guix store)
             (guix gexp)
             (ice-9 textual-ports)
             (spartan packages mainsail)
             (spartan services klipper)
             (spartan services moonraker)
             (srfi srfi-1)
             (srfi srfi-64))

(define (activation-wrapper action)
  ;; Build Guix's real activation wrapper, but execute only its service
  ;; snippet: the top-level script would modify the test runner's system.
  (with-store store
    (let* ((drv (run-with-store store
                  (lower-object
                   (activation-service->script
                    (service activation-service-type (list action))))))
           (output (derivation->output-path drv)))
      (build-derivations store (list drv))
      (let ((snippets (filter (lambda (path)
                                (string-suffix? "-activate-service.scm" path))
                              (references store output))))
        (unless (= 1 (length snippets))
          (error "expected one activation snippet" snippets))
        (car snippets)))))

(define (read-text path)
  (call-with-input-file path get-string-all))

(test-begin "printer-activation")
(define runner (test-runner-current))
(let ((directory (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp")
                                        "/printer-activation-XXXXXX"))))
  (dynamic-wind
    (const #t)
    (lambda ()
      (let* ((user (getpwuid (getuid)))
             (name (passwd:name user))
             (state (string-append directory "/klipper"))
             (run (string-append directory "/run"))
             (data (string-append directory "/moonraker"))
             (config (string-append state "/printer.cfg"))
             (fragment (string-append state "/config.d/macros.cfg"))
             (mainsail-file (string-append state "/mainsail.cfg"))
             (klipper
              (activation-wrapper
               ((@@ (spartan services klipper) klipper-activation)
                (klipper-configuration
                 (state-directory (string-append directory "//klipper/"))
                  (run-directory run)
                  (config-files
                   (list (cons "config.d/macros.cfg"
                               (plain-file "source-macros.cfg" "initial macro settings\n"))
                         (cons "printer.cfg"
                               (plain-file "source-printer.cfg" "[include config.d/macros.cfg]\n"))
                         (cons "mainsail.cfg"
                               (file-append mainsail-config
                                            "/share/mainsail-config/mainsail.cfg")))))
                #:user name)))
             (moonraker
              (activation-wrapper
               ((@@ (spartan services moonraker) moonraker-activation)
                (moonraker-configuration
                 (data-directory data)
                 (klipper-state-directory state))
                #:user name))))
        (test-assert "generated Moonraker activation initializes writable state"
          (begin
            (invoke moonraker)
            (and (string=? state (readlink (string-append data "/config")))
                 (every (lambda (path)
                          (let ((info (stat path)))
                            (and (= (stat:uid info) (getuid))
                                 (= (stat:gid info) (passwd:gid user))
                                 (= (stat:perms info) #o750))))
                        (list data (string-append data "/logs"))))))
        (test-equal "generated Klipper activation seeds the configuration"
           "[include config.d/macros.cfg]\n"
           (begin (invoke klipper) (read-text config)))
         (test-assert "activation seeds packaged Mainsail macros beside printer.cfg"
           (and (eq? 'regular (stat:type (lstat mainsail-file)))
                (string-contains
                 (read-text (string-append data "/config/mainsail.cfg"))
                 "[gcode_macro SET_PAUSE_AT_LAYER]")))
         (test-equal "relative fragment is writable and visible through Moonraker"
           '("initial macro settings\n" #o640)
           (list (read-text (string-append data "/config/config.d/macros.cfg"))
                 (stat:perms (stat fragment))))
          (test-equal "repeated activation resets printer.cfg and nested fragments"
            '("[include config.d/macros.cfg]\n" "initial macro settings\n" #o640 #o640)
           (begin
             (call-with-output-file config
               (lambda (port) (display "calibrated settings\n" port)))
             (call-with-output-file fragment
               (lambda (port) (display "edited macros\n" port)))
             (invoke klipper)
              (invoke moonraker)
              (list (read-text (string-append data "/config/printer.cfg"))
                    (read-text fragment)
                    (stat:perms (stat config))
                    (stat:perms (stat fragment)))))
          (test-equal "activation recreates a missing declared fragment"
            '("[include config.d/macros.cfg]\n" "initial macro settings\n")
           (begin
             (delete-file fragment)
             (invoke klipper)
             (list (read-text config) (read-text fragment))))))
    (lambda () (delete-file-recursively directory))))
(test-end "printer-activation")
(exit (zero? (test-runner-fail-count runner)))
