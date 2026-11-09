(define-module (spartan packages nut)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages libusb)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages networking)
  #:export (nut))

(define-public nut
  (package
    (name "nut")
    (version "2.8.5")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://networkupstools.org/source/2.8/nut-"
                                  version ".tar.gz"))
              (sha256
               (base32 "1hgf7rip199py7kjy7dk9icgmmr694w71yn4lcyv2r5pkvjk5gqq"))))
    (build-system gnu-build-system)
    (arguments
     (list #:configure-flags
           #~(list "--with-user=nut" "--with-group=nut"
                   "--with-statepath=/run/nut" "--with-altpidpath=/run/nut"
                   "--with-pidpath=/run/nut"
                   (string-append "--with-drvpath=" #$output "/libexec/nut")
                   (string-append "--with-udev-dir=" #$output "/lib/udev")
                   "--with-usb=yes" "--with-snmp=yes" "--with-openssl=yes"
                   "--without-python" "--without-python2" "--without-python3"
                   "--without-doc" "--without-cgi" "--without-libsystemd"
                   "--with-systemdsystemunitdir=no"
                   "--with-systemdshutdowndir=no"
                   "--with-systemdtmpfilesdir=no"
                   "--with-systemdsysusersdir=no"
                   "--with-systemdsystempresetdir=no")
           #:phases
           #~(modify-phases %standard-phases
               ;; Installation must not create or chown host runtime directories.
               (add-before 'install 'skip-runtime-directories
                 (lambda _
                   (substitute* "Makefile"
                     (("^install-data-hook:") "unused-install-data-hook:")))))))
    (native-inputs (list pkg-config))
    (inputs (list libusb net-snmp openssl))
    (home-page "https://networkupstools.org/")
    (synopsis "Monitor and control uninterruptible power supplies")
    (description
     "Network UPS Tools provides drivers for USB, serial and network-connected
power devices, the upsd network server, and monitoring and administration clients.")
    (license license:gpl2+)))
