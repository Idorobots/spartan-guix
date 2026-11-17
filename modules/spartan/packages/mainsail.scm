(define-module (spartan packages mainsail)
  #:use-module (gnu packages compression)
  #:use-module (guix build-system copy)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages))

(define-public mainsail
  (package
    (name "mainsail")
    (version "2.19.0")
    ;; This is the upstream-built frontend distributed by the manual installer.
    ;; Pin the release asset, rather than the moving releases/latest endpoint.
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/mainsail-crew/mainsail/"
                           "releases/download/v" version "/mainsail.zip"))
       (file-name (string-append name "-" version ".zip"))
       (sha256
        (base32 "12ipjfyl2d08n1lkh6fgay6gxws7air20bwwf3h6l745i5pxknf4"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan #~'(("./" "share/mainsail"))
      #:phases
      #~(modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              ;; The ZIP has no containing directory. Do not accidentally
              ;; select assets/ as the source directory during generic unpack.
              (mkdir "source")
              (chdir "source")
              (invoke "unzip" "-q" source)))
          (add-after 'install 'install-license
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((doc (string-append #$output "/share/doc/mainsail-" #$version)))
                (mkdir-p doc)
                (copy-file (assoc-ref inputs "license")
                           (string-append doc "/LICENSE")))))
          (add-after 'install-license 'check-release
            (lambda _
              (use-modules (ice-9 textual-ports))
              (let ((root (string-append #$output "/share/mainsail/")))
                (unless (and (file-exists? (string-append root "index.html"))
                             (file-exists? (string-append root "sw.js"))
                             (file-exists? (string-append root "config.json"))
                             (string=? (call-with-input-file
                                           (string-append root ".version") get-string-all)
                                       (string-append "v" #$version)))
                  (error "Incomplete or mismatched Mainsail release"))))))))
    (native-inputs
     `(("unzip" ,unzip)
       ("license"
        ,(origin
           (method url-fetch)
           (uri (string-append
                 "https://raw.githubusercontent.com/mainsail-crew/mainsail/v"
                 version "/LICENSE"))
           (file-name "LICENSE")
           (sha256
            (base32 "11k9nggwk1mgsrkdwgdjz65avrradxlpdgrdkc7ryjgn8jbxqwir"))))))
    (home-page "https://docs.mainsail.xyz/")
    (synopsis "Web interface for Klipper 3D printers")
    (description
     "Mainsail is a browser-based interface for Klipper through the Moonraker
API.  It provides printer controls, G-code uploads and previews, configuration
editing, temperature graphs, print history and webcam views.  This package
installs the official pre-built release in share/mainsail for a web server to
serve.  The frontend runs in the browser and needs no Node.js runtime on the
printer host.")
    (license license:gpl3)))
