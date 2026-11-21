(define-module (spartan packages klipperscreen)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gettext)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-web)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages xorg)
  #:use-module (guix build-system copy)
  #:use-module ((guix build-system pyproject) #:select (pypi-uri))
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix git-download) #:select (git-version))
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages))

(define python-websocket-client/klipperscreen
  (package
    (inherit python-websocket-client)
    (version "1.9.2")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "websocket_client" version))
              (sha256
               (base32 "1l04asw355ppvxlakcgxkxvad1yxjvyii0hj5scqdgj8b1a5gjqg"))))))

;; v0.4.7 sends an empty API key even on trusted connections. Use an
;; upstream snapshot containing the Moonraker 0.11 fix (issue #1760).
(define %klipperscreen-commit "a4ef4d2260fc2c733039b7ba2f58fab75ee49ef7")

(define-public klipperscreen
  (package
    (name "klipperscreen")
    (version (git-version "0.4.7" "1" %klipperscreen-commit))
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://codeload.github.com/KlipperScreen/KlipperScreen/"
                            "tar.gz/" %klipperscreen-commit))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
         (base32 "0lxb0yqpphmlby1vrqzjmqf6f1bp0h7xh9d1gj2ivv715xfdnk2s"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:modules '((guix build copy-build-system) (guix build utils) (srfi srfi-1))
      #:install-plan
      #~'(("screen.py" "share/klipperscreen/")
          ("config" "share/klipperscreen/")
          ("ks_includes" "share/klipperscreen/ks_includes" #:exclude (".po"))
          ("panels" "share/klipperscreen/")
          ("styles" "share/klipperscreen/")
          ("LICENSE" "share/doc/klipperscreen/")
          ("README.md" "share/doc/klipperscreen/"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'configure-runtime
            (lambda _
              (substitute* "ks_includes/functions.py"
                 (("\"libXext\\.so\\.6\"")
                  (string-append "\"" #$(file-append libxext "/lib/libXext.so.6") "\"")))
              (substitute* "ks_includes/KlippyGtk.py"
                (("ks_includes/emptyCursor\\.xbm")
                 (string-append #$output "/share/klipperscreen/ks_includes/emptyCursor.xbm")))
              ;; The optional network panel uses NetworkManager via systemd.
              (substitute* '("config/main_menu.conf" "config/print_menu.conf"
                             "config/splash_menu.conf")
                (("^panel: network\n") "panel: network\nenable: False\n"))
              (for-each (lambda (po)
                          (invoke "msgfmt" "-o"
                                  (string-append (string-drop-right po 3) ".mo") po))
                        (find-files "ks_includes/locales" "\\.po$"))))
          (add-after 'install 'wrap-launcher
            (lambda _
              (let ((launcher (string-append #$output "/bin/klipperscreen")))
                (mkdir-p (dirname launcher))
                (call-with-output-file launcher
                  (lambda (port)
                    (format port "#!~a~%exec ~a ~a/share/klipperscreen/screen.py \"$@\"~%"
                            #$(file-append bash-minimal "/bin/sh")
                            #$(file-append python "/bin/python3") #$output)))
                (chmod launcher #o755)
                (apply wrap-program launcher
                       `(("PATH" ":" prefix (,#$(file-append xset "/bin")
                                              ,#$(file-append xsetroot "/bin")))
                         ("XDG_DATA_DIRS" ":" prefix
                          (,#$(file-append shared-mime-info "/share")))
                         ,@(filter-map
                            (lambda (name)
                              (and=> (getenv name)
                                     (lambda (value) `(,name ":" prefix (,value)))))
                            '("GUIX_PYTHONPATH" "GI_TYPELIB_PATH"
                              "GUIX_GDK_PIXBUF_MODULE_FILES")))))))
          (add-after 'wrap-launcher 'check-launcher
            (lambda _
              ;; Test the installed wrapper, without the build environment's
              ;; search paths or a running graphical session.
              (for-each unsetenv '("GUIX_PYTHONPATH" "GI_TYPELIB_PATH"
                                   "XDG_DATA_DIRS" "GUIX_GDK_PIXBUF_MODULE_FILES"))
              (setenv "HOME" (getcwd))
              (invoke (string-append #$output "/bin/klipperscreen") "--help"))))))
    (native-inputs (list gettext-minimal))
    (inputs (list bash-minimal gobject-introspection gtk+ libxext python
                  python-jinja2 python-mpv python-psutil python-pycairo
                   python-pygobject python-requests python-websocket-client/klipperscreen
                  shared-mime-info xset xsetroot))
    (home-page "https://klipperscreen.readthedocs.io/")
    (synopsis "Touchscreen interface for Klipper 3D printers")
    (description "KlipperScreen is a GTK interface for controlling Klipper 3D
printers through the Moonraker API.  It provides controls for printing, motion,
temperature and calibration.  It runs inside an X11 or Wayland session.  This
package leaves Wi-Fi configuration to the operating system.")
    (license license:agpl3+)))
