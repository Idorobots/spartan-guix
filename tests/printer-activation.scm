(use-modules (gnu services)
             (guix build utils)
             (guix derivations)
             (guix monads)
             (guix store)
             (guix gexp)
             (ice-9 textual-ports)
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
             (klipper
              (activation-wrapper
               ((@@ (spartan services klipper) klipper-activation)
                (klipper-configuration
                 (state-directory (string-append directory "//klipper/"))
                 (run-directory run)
                 (config-file (plain-file "printer.cfg" "initial printer settings\n")))
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
          "initial printer settings\n"
          (begin (invoke klipper) (read-text config)))
        (test-equal "repeated activation preserves the existing configuration"
          "calibrated settings\n"
          (begin
            (call-with-output-file config
              (lambda (port) (display "calibrated settings\n" port)))
            (invoke klipper)
            (invoke moonraker)
            (read-text (string-append data "/config/printer.cfg"))))))
    (lambda () (delete-file-recursively directory))))
(test-end "printer-activation")
(exit (zero? (test-runner-fail-count runner)))
