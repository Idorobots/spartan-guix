(define-module (spartan packages moonraker)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module (guix build-system pyproject)
  #:use-module (gnu packages check)
  #:use-module (gnu packages databases)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages messaging)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-check)
  #:use-module (gnu packages python-crypto)
  #:use-module (gnu packages python-web)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages tls)
  #:use-module (spartan packages moonraker-provider-shepherd))

(define python-paho-mqtt/renewed-tests
  (package
    (inherit python-paho-mqtt)
    (arguments
     (substitute-keyword-arguments (package-arguments python-paho-mqtt)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-before 'check 'renew-test-certificates
              (lambda _
                ;; The checked-in TLS fixtures have expired.  Renew them only
                ;; in the build tree so the TLS tests remain enabled.
                (with-directory-excursion "tests/ssl"
                  (setenv "HOME" (getcwd))
                  (invoke "sh" "gen.sh"))))))))
    (native-inputs (modify-inputs (package-native-inputs python-paho-mqtt)
                    (prepend openssl perl)))))

(define-public python-streaming-form-data
  (package
    (name "python-streaming-form-data")
    (version "1.19.1")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "streaming_form_data" version))
              (sha256
               (base32 "16yxqjyj42dg2dyjb4hlgspcpw38rcxd3cfy6c80vb22k98dswl1"))))
    (build-system pyproject-build-system)
    (arguments
     (list #:test-flags
           ;; These targets exercise cloud storage, not multipart parsing.
           #~(list "--ignore=tests/test_targets.py")))
    (native-inputs (list python-setuptools python-wheel python-pytest
                         python-requests-toolbelt))
    (propagated-inputs (list python-smart-open))
    (home-page "https://github.com/siddhantgoel/streaming-form-data")
    (synopsis "Streaming multipart form-data parser")
    (description "This library incrementally parses multipart/form-data streams,
allowing large uploads to be processed without buffering them in memory.")
    (license license:expat)))

(define-public python-preprocess-cancellation
  (package
    (name "python-preprocess-cancellation")
    (version "0.2.1")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "preprocess_cancellation" version))
              (sha256
               (base32 "0yff6fa9kai8ac5fh8jiks2dr0hhz6m7r4znvggknq513d725wg2"))))
    (build-system pyproject-build-system)
    (arguments
     (list
      ;; The source distribution does not include the upstream tests.
      #:tests? #f
      #:build-backend "poetry.core.masonry.api"))
    (native-inputs (list python-poetry-core))
    (home-page "https://github.com/kageurufu/cancelobject-preprocessor")
    (synopsis "Add Klipper object-cancellation markers to G-code")
    (description "This package processes slicer G-code to add the object markers
used by Klipper's exclude-object feature and Moonraker's object processing.")
    (license license:gpl3)))

(define-public python-periphery
  (package
    (name "python-periphery")
    (version "2.4.1")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "python-periphery" version))
              (sha256
               (base32 "12p881zc96iqv406c261x3i530d622mj11w7drv6yalq6vbn3m31"))))
    (build-system pyproject-build-system)
    ;; Upstream's tests require physical GPIO, SPI, I2C and other devices.
    (arguments (list #:tests? #f))
    (native-inputs (list python-setuptools python-wheel))
    (home-page "https://github.com/vsergeev/python-periphery")
    (synopsis "Linux peripheral I/O from Python")
    (description "Python-periphery provides userspace access to GPIO, LED, PWM,
SPI, I2C, MMIO and serial interfaces on Linux.")
    (license license:expat)))

;; Moonraker needs newer APIs than the versions currently provided by Guix.
(define python-inotify-simple/moonraker
  (package
    (inherit python-inotify-simple)
    (version "2.0.1")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "inotify_simple" version))
              (sha256
               (base32 "0b6w3ia6w4zldq70ncj7pljdwkl0cm3yjbgbyjlp3gc3hayvn47h"))))
    (arguments
     (list #:test-backend #~'custom
           #:test-flags
           #~(list "-c" (string-append
                         "import tempfile; from inotify_simple import INotify, flags; "
                         "d = tempfile.TemporaryDirectory(); i = INotify(); "
                         "i.add_watch(d.name, flags.CREATE); "
                         "open(d.name + '/created', 'w').close(); "
                         "assert i.read(timeout=1000)[0].name == 'created'; "
                         "i.close(); d.cleanup()"))))
    (license license:bsd-2)))

(define python-zeroconf/moonraker
  (package
    (inherit python-zeroconf)
    (version "0.131.0")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "zeroconf" version))
              (sha256
               (base32 "0cgkfm9xmx5syzk340qrjfpj966al1ygsyi1w2jl984jj7lk3i4h"))))
    (arguments
     (list
      ;; Use the upstream-supported pure Python build, as Moonraker does.
      #:phases #~(modify-phases %standard-phases
                   (add-before 'build 'disable-cython
                     (lambda _ (setenv "SKIP_CYTHON" "1"))))
      ;; Exercise the protocol/cache logic without requiring multicast access.
      #:test-flags #~(list "-o" "addopts=" "tests/test_cache.py"
                          "tests/test_dns.py" "tests/test_exceptions.py"
                          "tests/test_history.py")))
    (native-inputs (list python-poetry-core python-setuptools python-wheel
                         python-pytest python-pytest-asyncio python-pytest-timeout))))

(define-public moonraker
  (package
    (name "moonraker")
    (version "0.11.0")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://codeload.github.com/Arksine/moonraker/tar.gz/refs/tags/v"
                    version))
              (file-name (string-append name "-" version ".tar.gz"))
              (sha256
               (base32 "1cwa673841ancpdkkdaq8iyf5zrbxh7k5436sh6b6169kwp09adv"))))
    (build-system pyproject-build-system)
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'register-shepherd-provider
            (lambda _
              (invoke "patch" "--batch" "--fuzz=0" "-p1" "-i"
                      #$(file-append moonraker-provider-shepherd
                                     "/share/moonraker-provider-shepherd/patches/moonraker-0.11.0-shepherd.patch"))))
          (add-after 'unpack 'configure-build
            (lambda _
              ;; Release archives have no Git metadata.  PDM accepts a fixed
              ;; version without probing Git or using the current date.
              (setenv "PDM_BUILD_SCM_VERSION" #$version)
              ;; Guix's PySerial contains fixes newer than upstream's venv pin.
              ;; Its ldap3 2.9.1 package reports 2.9 in distribution metadata.
              (substitute* "pyproject.toml"
                (("pyserial==3.4") "pyserial>=3.4")
                (("ldap3==2.9.1") "ldap3>=2.9"))
              ;; Guix already retains the declarative configuration; do not
              ;; attempt to create upstream's adjacent backup in the store.
              (substitute* "moonraker/confighelper.py"
                (("        backup = cfg.parent.joinpath")
                 (string-append "        if cfg.resolve().is_relative_to('/gnu/store'):\n"
                                "            return\n"
                                "        backup = cfg.parent.joinpath")))
              ;; Klipper's package intentionally omits its optional docs tree.
              (substitute* "moonraker/components/file_manager/file_manager.py"
                (("            self.register_directory\\(\"docs\", docs_path\\)")
                 (string-append "            if os.path.isdir(docs_path):\n"
                                "                self.register_directory(\"docs\", docs_path)")))))
          (replace 'check
            (lambda* (#:key tests? #:allow-other-keys)
              (when tests?
                ;; Check installed core and optional imports without printer
                ;; hardware; tests/moonraker-runtime.py exercises the API.
                (invoke "python" "-c"
                        (string-append
                         "import importlib; "
                         "mods = ['application', 'authorization', 'database', "
                         "'dbus_manager', 'file_manager.file_manager', 'gpio', "
                         "'history', 'machine', 'mqtt', 'notifier', 'ldap', 'zeroconf']; "
                         "[importlib.import_module('moonraker.components.' + m) "
                         "for m in mods]; "
                         "import preprocess_cancellation; "
                         "from moonraker_provider_shepherd.provider import ShepherdProvider; "
                         "from moonraker.components.machine import BaseProvider; "
                         "assert issubclass(ShepherdProvider, BaseProvider)")))))
          (add-after 'wrap 'wrap-system-tools
            (lambda _
              ;; Machine information invokes these commands even with the
              ;; system-service provider disabled.  Do not rely on host PATH.
              (wrap-program (string-append #$output "/bin/moonraker")
                `("PATH" prefix
                  (,(string-append #$iproute "/sbin")
                   ,(string-append #$wireless-tools "/sbin")))
                `("SSL_CERT_DIR" prefix
                  (,(string-append #$nss-certs "/etc/ssl/certs"))))))
          (add-after 'wrap-system-tools 'check-installed
            (lambda* (#:key tests? target #:allow-other-keys)
              (when (and tests? (not target))
                (invoke "env" "-u" "GUIX_PYTHONPATH" "-u" "PYTHONPATH"
                        "-u" "PYTHONHOME"
                        (string-append #$output "/bin/moonraker") "--help")))))))
    (native-inputs (list python-pdm-backend python-setuptools))
    (inputs (list iproute wireless-tools nss-certs))
    (propagated-inputs
     (list python-tornado python-pyserial python-pillow python-streaming-form-data
           python-distro python-inotify-simple/moonraker python-libnacl
           python-paho-mqtt/renewed-tests python-zeroconf/moonraker
           python-preprocess-cancellation python-jinja2
           python-dbus-fast python-apprise python-ldap3 python-periphery
           python-importlib-metadata moonraker-provider-shepherd
           ;; Prevent runtime pip installation when importing an old database.
           python-lmdb))
    (home-page "https://moonraker.readthedocs.io/")
    (synopsis "HTTP and WebSocket API server for Klipper")
    (description "Moonraker exposes Klipper's printer API over HTTP and
WebSockets, manages G-code uploads and metadata, and stores printer history.
It connects to Klippy over a Unix socket and can serve clients such as Mainsail.")
    (license license:gpl3)))
