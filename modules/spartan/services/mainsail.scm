(define-module (spartan services mainsail)
  #:use-module (gnu services web)
  #:use-module (guix gexp)
  #:use-module (spartan packages mainsail)
  #:use-module (srfi srfi-1)
  #:export (%mainsail-nginx-configuration mainsail-nginx-configuration))

(define %no-cache
  '("add_header Cache-Control \"no-store, no-cache, must-revalidate\";"))

(define %proxy-headers
  '("proxy_set_header Host $http_host;"
    "proxy_set_header X-Real-IP $remote_addr;"
    "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"))

(define (webcam-location number)
  (nginx-location-configuration
   (uri (if (= number 1) "/webcam/"
            (string-append "/webcam" (number->string number) "/")))
   (body (list "postpone_output 0;"
               "proxy_buffering off;"
               "proxy_ignore_headers X-Accel-Buffering;"
               "access_log off;"
               ;; nginx has no 'error_log off' directive; use the null device.
               "error_log /dev/null;"
               (string-append "proxy_pass http://mjpgstreamer"
                              (number->string number) "/;")))))

(define* (mainsail-nginx-configuration
          #:key (package mainsail)
          (listen '("80 default_server")) (server-name '("_"))
          (moonraker-address "127.0.0.1:7125")
          (webcams '("127.0.0.1:8080" "127.0.0.1:8081"
                     "127.0.0.1:8082" "127.0.0.1:8083"))
          (gzip? #t) (config-file #f))
  "Return an nginx configuration following Mainsail's manual installation.
PACKAGE provides share/mainsail. LISTEN and SERVER-NAME use the nginx service's
list syntax. MOONRAKER-ADDRESS and WEBCAMS are nginx upstream server addresses;
each webcam gets /webcam/, /webcam2/, etc. An empty list disables webcam routes.
CONFIG-FILE optionally supplies a file-like config.json. GZIP? controls static
response compression. The returned record can be passed to nginx-service-type."
  (nginx-configuration
   (extra-content
    '("map $http_upgrade $connection_upgrade {"
      "    default upgrade;"
      "    '' close;"
      "}"))
   (upstream-blocks
    (cons (nginx-upstream-configuration
           (name "apiserver") (servers (list moonraker-address))
           (extra-content '("ip_hash;")))
          (map (lambda (address number)
                 (nginx-upstream-configuration
                  (name (string-append "mjpgstreamer" (number->string number)))
                  (servers (list address)) (extra-content '("ip_hash;"))))
               webcams (iota (length webcams) 1))))
   (server-blocks
    (list
     (nginx-server-configuration
      (listen listen) (server-name server-name)
      (root (file-append package "/share/mainsail"))
      (index '("index.html"))
      (raw-content
       (append '("client_max_body_size 0;"
                 "proxy_request_buffering off;")
               (if gzip?
                   '("gzip on;"
                     "gzip_vary on;"
                     ;; 'any' includes the manual's other gzip_proxied flags.
                     "gzip_proxied any;"
                     "gzip_comp_level 4;"
                     "gzip_buffers 16 8k;"
                     "gzip_http_version 1.1;"
                     "gzip_types text/plain text/css text/xml text/javascript application/javascript application/x-javascript application/json application/xml;")
                   '("gzip off;"))))
      (locations
       (append
        (list
         (nginx-location-configuration
          (uri "/") (body '("try_files $uri $uri/ /index.html;")))
         (nginx-location-configuration (uri "= /index.html") (body %no-cache))
         (nginx-location-configuration (uri "= /sw.js") (body %no-cache))
         (nginx-location-configuration
          (uri "= /config.json")
          (body (append (if config-file
                            (list #~(format #f "alias ~s;" #$config-file))
                            '())
                        %no-cache)))
         (nginx-location-configuration
          (uri "/websocket")
          (body (append '("proxy_pass http://apiserver/websocket;"
                          "proxy_http_version 1.1;"
                          "proxy_set_header Upgrade $http_upgrade;"
                          "proxy_set_header Connection $connection_upgrade;"
                          "proxy_read_timeout 86400;")
                        %proxy-headers)))
         (nginx-location-configuration
          (uri "~ ^/(printer|api|access|machine|server)/")
          (body (append '("proxy_pass http://apiserver$request_uri;"
                          "proxy_http_version 1.1;"
                          "proxy_set_header Upgrade $http_upgrade;"
                          "proxy_set_header X-Scheme $scheme;")
                        %proxy-headers))))
        (map webcam-location (iota (length webcams) 1)))))))))

(define %mainsail-nginx-configuration
  (mainsail-nginx-configuration))
