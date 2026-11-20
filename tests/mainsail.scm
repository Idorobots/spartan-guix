(use-modules (gnu) (gnu services shepherd) (gnu services web)
             (guix build utils) (guix derivations) (guix gexp)
             (guix monads) (guix store) (ice-9 textual-ports)
             (spartan packages mainsail) (spartan services mainsail)
             (srfi srfi-1) (srfi srfi-64))

(test-begin "mainsail")
(define runner (test-runner-current))
(define temporary (mkdtemp "/tmp/spartan-mainsail-XXXXXX"))
(define (realize file)
  (with-store store
    (let ((drv (run-with-store store
                 (gexp->derivation "mainsail-test-reference"
                   #~(call-with-output-file #$output
                       (lambda (port) (display #$file port)))))))
      (build-derivations store (list drv))
      (call-with-input-file (derivation->output-path drv) get-string-all))))
(define (extension target)
  (find (lambda (item) (eq? target (service-extension-target item)))
        (service-type-extensions nginx-service-type)))
(define (config-file config)
  (file-append
   (cadar ((service-extension-compute (extension etc-service-type)) config))
   "/nginx.conf"))
(define (unused-port)
  (let ((listener (socket AF_INET SOCK_STREAM 0)))
    (bind listener AF_INET INADDR_LOOPBACK 0)
    (let ((port (sockaddr:port (getsockname listener))))
      (close-port listener)
      port)))

(define default %mainsail-nginx-configuration)
(test-equal "default HTTP listener matches the manual setup"
  '("80 default_server")
  (nginx-server-configuration-listen
   (car (nginx-configuration-server-blocks default))))
(test-equal "default backends match Moonraker and the four manual webcam ports"
  '(("127.0.0.1:7125") ("127.0.0.1:8080") ("127.0.0.1:8081")
    ("127.0.0.1:8082") ("127.0.0.1:8083"))
  (map nginx-upstream-configuration-servers
       (nginx-configuration-upstream-blocks default)))
(test-equal "webcams can be disabled without dropping the API upstream" '("apiserver")
  (map nginx-upstream-configuration-name
       (nginx-configuration-upstream-blocks
        (mainsail-nginx-configuration #:webcams '()))))
(test-assert "nginx starts independently of printer daemons"
  (every (lambda (item)
           (not (any (lambda (name) (memq name '(klipper moonraker)))
                     (shepherd-service-requirement item))))
         ((service-extension-compute (extension shepherd-root-service-type)) default)))
(test-error "Mainsail rejects a list of config files" #t
  (mainsail-nginx-configuration #:config-file (list (plain-file "config.json" "{}"))))

(define port (unused-port))
(define backend-port (unused-port))
(define backend (string-append "127.0.0.1:" (number->string backend-port)))
(define custom-config (plain-file "mainsail-config.json" "{\"defaultLocale\":\"de\"}\n"))
(define runtime
  (nginx-configuration
   (inherit (mainsail-nginx-configuration
             #:listen (list (string-append "127.0.0.1:" (number->string port)))
             #:moonraker-address backend #:webcams (make-list 4 backend)
              #:config-file custom-config))
   (run-directory (string-append temporary "/run"))
   (log-directory (string-append temporary "/logs"))))
(define checked-default
  (nginx-configuration
   (inherit default)
   (run-directory (nginx-configuration-run-directory runtime))
   (log-directory (nginx-configuration-log-directory runtime))))
(test-assert "default nginx configuration has no config.json alias"
  (not (string-contains (call-with-input-file (realize (config-file checked-default))
                                             get-string-all)
                        "mainsail-config.json")))
(test-assert "installed release and actual nginx configuration serve and proxy correctly"
  (zero? (system*
          (realize (file-append (@ (gnu packages python) python) "/bin/python3"))
          (string-append (dirname (current-filename)) "/mainsail-runtime.py")
          temporary (realize mainsail)
          (realize (file-append (nginx-configuration-nginx runtime) "/sbin/nginx"))
          (realize (config-file checked-default)) (realize (config-file runtime))
          (number->string port) (number->string backend-port))))

(delete-file-recursively temporary)
(test-end "mainsail")
(exit (zero? (test-runner-fail-count runner)))
