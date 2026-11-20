(define-module (spartan services klipperscreen)
  #:use-module (gnu packages xorg)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services desktop)
  #:use-module (gnu services xorg)
  #:use-module (gnu system pam)
  #:use-module (guix gexp)
  #:use-module (spartan packages klipperscreen)
  #:export (elogind-for-greetd-service-type
            klipperscreen-xorg-session))

(define elogind-for-greetd-service-type
  (service-type
   (inherit elogind-service-type)
   (name 'elogind-for-greetd)
   (extensions
    (map (lambda (extension)
           (if (eq? pam-root-service-type (service-extension-target extension))
               (service-extension
                pam-root-service-type
                (lambda (config)
                  (map (lambda (pam)
                         (pam-extension
                          (transformer
                           (lambda (service)
                             (if (string=? "greetd" (pam-service-name service))
                                 ((pam-extension-transformer pam) service)
                                 service)))))
                       ((service-extension-compute extension) config))))
               extension))
         (service-type-extensions elogind-service-type)))
   (description "Run elogind for greetd without making other PAM services
depend on it.  Configure greetd to start after the @code{elogind} service.")))

(define* (klipperscreen-xorg-session #:key (package klipperscreen)
                                    (xorg (xorg-configuration
                                           (modules (list xf86-input-libinput))
                                           (drivers '("modesetting"))))
                                    (xrandr-arguments '()))
  "Return a greetd session that starts KlipperScreen as the only X11 client.
Apply XRANDR-ARGUMENTS, when nonempty, before starting the application. The
host must provide an active local VT and seat management (for example elogind)."
  (define launcher
    (program-file
     "klipperscreen-xinitrc"
     #~(begin
         (let ((arguments '#$xrandr-arguments))
           (unless (null? arguments)
             (unless (zero? (apply system* #$(file-append xrandr "/bin/xrandr") arguments))
               (format (current-error-port) "Could not configure the KlipperScreen output.~%"))))
         (let ((app #$(file-append package "/bin/klipperscreen")))
           (execl app app "--logfile" (string-append (getenv "HOME") "/KlipperScreen.log"))))))
  ;; greetd's extra-env accepts literal values; lower the XINITRC program
  ;; to its store path in a gexp instead.
  (define startx (xorg-start-command-xinit xorg))
  (define session-command
    (program-file
     "klipperscreen-xorg-session"
     #~(begin
         (setenv "XINITRC" #$launcher)
         (execl #$startx #$startx))))
  (greetd-user-session
   (command session-command)
   (command-args '())
   (xdg-session-type "x11")))
