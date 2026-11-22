;; SPDX-License-Identifier: MIT
(use-modules (gnu services)
             (gnu services shepherd)
             (gnu system)
             (gnu system shadow)
             (guix gexp)
             (ice-9 format)
             (spartan packages nut)
             (spartan packages spartan-sensor-mesh)
             (spartan services spartan-sensor-mesh)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "spartan-sensor-mesh")
(define runner (test-runner-current))

(define (extension target)
  (find (lambda (extension)
          (eq? (service-extension-target extension) target))
        (service-type-extensions spartan-sensor-mesh-service-type)))

(define (extension-value target config)
  ((service-extension-compute (extension target)) config))

(define (services config)
  (extension-value shepherd-root-service-type config))

(define (form-string form)
  (format #f "~s" form))

(define (start-form config)
  (gexp->approximate-sexp
   (shepherd-service-start (car (services config)))))

(define (keyword-argument form keyword)
  (let loop ((rest form))
    (cond ((null? rest) #f)
          ((eq? (car rest) keyword) (cadr rest))
          (else (loop (cdr rest))))))

(define default (spartan-sensor-mesh-configuration))
(define service (car (services default)))

(test-equal "default provision" '(spartan-sensor-mesh)
  (shepherd-service-provision service))
(test-equal "default requirements" '(user-processes networking)
  (shepherd-service-requirement service))
(test-equal "default data directory" "/var/lib/spartan-sensor-mesh"
  (spartan-sensor-mesh-configuration-data-directory default))
(test-equal "default log file" "/var/lib/spartan-sensor-mesh/shepherd.log"
  (spartan-sensor-mesh-configuration-log-file default))
(test-assert "default start form runs as ssm and logs to the data directory"
  (let ((form (start-form default)))
    (and (member "ssm" form)
         (member "/var/lib/spartan-sensor-mesh/shepherd.log" form)
         (string-contains (form-string form)
                          "HOME=/var/lib/spartan-sensor-mesh"))))
(test-assert "default UI root is the packaged UI assets"
  (let ((environment
         (keyword-argument (start-form default) #:environment-variables)))
    (and environment
         (string-contains (form-string environment) "REST_DATA_PATH=")
         (string-contains (form-string environment) "(*approximate*)"))))
(define custom
  (spartan-sensor-mesh-configuration
   (config-file "/etc/ssm/config.json")
   (application-config "/etc/ssm/application.conf")
   (ui-root "/srv/ssm/ui")
   (rest-host "127.0.0.1")
   (rest-port 9090)))
(define custom-text (form-string (start-form custom)))
(test-assert "custom node config is passed as the first argument"
  (string-contains custom-text "/etc/ssm/config.json"))
(test-assert "custom application config is exported"
  (and (string-contains custom-text "JAVA_TOOL_OPTIONS=-Dconfig.file=")
       (string-contains custom-text "/etc/ssm/application.conf")))
(test-assert "custom UI root is exported"
  (and (string-contains custom-text "REST_DATA_PATH=")
       (string-contains custom-text "/srv/ssm/ui")))
(test-assert "custom REST host and port are exported"
  (and (string-contains custom-text "REST_HOST=")
       (string-contains custom-text "127.0.0.1")
       (string-contains custom-text "REST_PORT=")
       (string-contains custom-text "9090")))

(define nut-config
  (spartan-sensor-mesh-configuration (nut nut)))
(test-assert "NUT adds its bin directories to PATH"
  (let ((environment
         (keyword-argument (start-form nut-config) #:environment-variables)))
    (and environment
         (string-contains (form-string environment) "PATH=")
         (string-contains (form-string environment) "(*approximate*)"))))

(test-assert "data directory is normalized"
  (string-contains
   (form-string
    (start-form
     (spartan-sensor-mesh-configuration
      (data-directory "//var/lib/spartan-sensor-mesh/"))))
   "HOME=/var/lib/spartan-sensor-mesh"))

(for-each
 (lambda (config)
   (test-error "invalid configuration is rejected" #t (services config)))
 (list (spartan-sensor-mesh-configuration (config-file "relative"))
       (spartan-sensor-mesh-configuration (application-config "relative"))
       (spartan-sensor-mesh-configuration (ui-root "relative"))
       (spartan-sensor-mesh-configuration (rest-port 0))
       (spartan-sensor-mesh-configuration (rest-port 65536))
       (spartan-sensor-mesh-configuration (data-directory "/"))
       (spartan-sensor-mesh-configuration (data-directory "/gnu/store/test"))
       (spartan-sensor-mesh-configuration (log-file "relative"))
       (spartan-sensor-mesh-configuration (user "root"))
       (spartan-sensor-mesh-configuration (nut "not-a-package"))))

(test-assert "service type has a default configuration"
  (spartan-sensor-mesh-configuration?
   (service-type-default-value spartan-sensor-mesh-service-type)))

(test-assert "activation creates the data directory"
  (string-contains
   (form-string
    (gexp->approximate-sexp
     (extension-value activation-service-type default)))
   "/var/lib/spartan-sensor-mesh"))

(test-assert "account extension creates the ssm user and group"
  (let ((accounts (extension-value account-service-type default)))
    (and (any (lambda (account)
                (and (user-group? account)
                     (string=? (user-group-name account) "ssm")))
              accounts)
         (any (lambda (account)
                (and (user-account? account)
                     (string=? (user-account-name account) "ssm")))
              accounts))))

(test-equal "profile extension includes the package"
  (list spartan-sensor-mesh)
  (extension-value profile-service-type default))

(test-end "spartan-sensor-mesh")
(exit (zero? (test-runner-fail-count runner)))
