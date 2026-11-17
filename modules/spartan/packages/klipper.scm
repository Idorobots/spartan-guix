(define-module (spartan packages klipper)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages libffi)
  #:export (klipper))

(define-public klipper
  (package
    (name "klipper")
    (version "0.13.0")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://codeload.github.com/Klipper3d/klipper/tar.gz/refs/tags/v"
                    version))
              (file-name (string-append "klipper-" version ".tar.gz"))
              (sha256
               (base32 "0nzb8l2i2n8flsm7f17xvvw1wnk1czlpf2l45qydk1j9f9sy9xz6"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          ;; Klipper has no configure script or conventional Python installer.
          (delete 'configure)
          (replace 'build
            (lambda _
              ;; Klipper normally rebuilds its helpers when source timestamps
              ;; change.  The store is read-only, so only build a missing
              ;; helper and use the packaged library thereafter.
              (substitute* "klippy/chelper/__init__.py"
                (("return not obj_times or max\\(src_times\\) > min\\(obj_times\\)")
                 "return not obj_times"))
              ;; Build both the host C helper and the SD-card flashing helper
              ;; now, rather than requiring a compiler on the running host.
              (invoke "python3" "klippy/chelper/__init__.py")
              (setenv "PYTHONPATH" "scripts/spi_flash:klippy")
              (invoke "python3" "-c"
                      "import fatfs_lib; fatfs_lib.get_fatfs_ffi()")))
          (replace 'check
            (lambda* (#:key tests? #:allow-other-keys)
              (when tests?
                ;; Upstream's import test checks Klippy's optional modules
                ;; without requiring a configured printer or an MCU.
                (invoke "python3" "klippy/klippy.py" "--import-test"))))
          (delete 'install)
          (add-after 'check 'install-source
            (lambda _
              (let ((root (string-append #$output "/share/klipper")))
                (mkdir-p root)
                ;; Retain all host modules, MCU sources, bundled libraries and
                ;; supporting tools, without copying CI files, docs or tests
                ;; into the package and the RAM-backed firmware workspace.
                (for-each
                 (lambda (directory)
                   (copy-recursively
                    directory (string-append root "/" directory)
                    #:select? (lambda (file stat)
                                (not (or (string=? (basename file) "__pycache__")
                                         (string-suffix? ".pyc" file))))))
                 '("config" "klippy" "lib" "scripts" "src"))
                (for-each (lambda (file) (install-file file root))
                          '("Makefile" "COPYING" "README.md"))
                ;; Klippy reads this when the installed tree has no Git metadata.
                (call-with-output-file (string-append root "/klippy/.version")
                  (lambda (port) (display #$version port) (newline port))))))
          (add-after 'install-source 'configure-firmware-tools
            (lambda _
              (let ((root (string-append #$output "/share/klipper"))
                    (python (string-append #$python "/bin/python3"))
                    (python-path (getenv "GUIX_PYTHONPATH")))
                ;; Make the firmware build self-contained with respect to
                ;; Python, including when this tree is copied into /run.
                ;; Board-specific compilers and flashing utilities stay external.
                (substitute* (string-append root "/Makefile")
                  (("^PYTHON=python3")
                   (string-append "PYTHON=" python "\n"
                                  "export GUIX_PYTHONPATH := " python-path)))
                ;; Upstream's SD-card script assumes ~/klippy-env.  Set its
                ;; interpreter and dependencies in the script itself so a
                ;; writable copy still uses its own local firmware outputs.
                ;; A wrap-program wrapper here would point back into the store.
                (substitute* (string-append root "/scripts/flash-sdcard.sh")
                  (("^KLIPPY_ENV=.*")
                   (format #f
                           (string-append "KLIPPY_ENV=~s~%"
                                          "export GUIX_PYTHONPATH=~s"
                                          "${GUIX_PYTHONPATH:+:}$GUIX_PYTHONPATH~%")
                           python python-path))))))
          (add-after 'configure-firmware-tools 'install-commands
            (lambda _
              (let ((root (string-append #$output "/share/klipper"))
                    (bin (string-append #$output "/bin"))
                    (python (string-append #$python "/bin/python3"))
                    (python-path (getenv "GUIX_PYTHONPATH")))
                (mkdir-p bin)
                ;; Expose stable entry points without modifying Klipper's
                ;; source layout, which its scripts use for relative imports.
                (for-each
                 (lambda (entry)
                   (let ((file (string-append bin "/" (car entry))))
                     (call-with-output-file file
                       (lambda (port)
                         (format port "#!/bin/sh~%exec ~s ~s \"$@\"~%"
                                 (cadr entry)
                                 (string-append root (caddr entry)))))
                     (chmod file #o755)))
                 `(("klippy" ,python "/klippy/klippy.py")
                   ("klipper-flash-sdcard" ,(which "bash") "/scripts/flash-sdcard.sh")))
                ;; Only the Klippy entry point needs wrapping; the SD-card
                ;; script and firmware Makefile already set their environment.
                (wrap-program (string-append bin "/klippy")
                  `("GUIX_PYTHONPATH" prefix (,python-path))))))
          (add-after 'patch-shebangs 'check-installed
            (lambda* (#:key tests? target #:allow-other-keys)
              (when (and tests? (not target))
                ;; Exercise the installed launchers, not the build tree's
                ;; Python environment.  Neither command needs printer hardware.
                ;; Do not repopulate the installed tree with bytecode caches.
                (for-each
                 (lambda (command)
                   (apply invoke "env"
                          "-u" "GUIX_PYTHONPATH" "-u" "PYTHONPATH" "-u" "PYTHONHOME"
                          "PYTHONDONTWRITEBYTECODE=1"
                          command))
                 (list (list (string-append #$output "/bin/klippy") "--import-test")
                       (list (string-append #$output "/bin/klipper-flash-sdcard")
                             "-l")))))))))
    (inputs (list python python-cffi python-greenlet python-jinja2
                  python-pyserial python-can python-setuptools))
    (home-page "https://www.klipper3d.org/")
    (synopsis "Host software and tools for Klipper 3D printer firmware")
    (description
     "Klipper runs printer control software on a Linux host and communicates
with firmware on one or more printer microcontrollers.  This package provides
Klippy, its upstream source and MCU firmware build and flashing scripts.")
    (license license:gpl3+)))
