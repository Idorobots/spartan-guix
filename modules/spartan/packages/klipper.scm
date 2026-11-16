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
          (replace 'install
            (lambda _
              (let* ((root (string-append #$output "/share/klipper"))
                     (bin (string-append #$output "/bin"))
                     (python (string-append #$python "/bin/python3"))
                     (python-path (getenv "GUIX_PYTHONPATH")))
                (mkdir-p root)
                (copy-recursively "." root)
                ;; Klippy reads this when the installed tree has no Git metadata.
                (call-with-output-file (string-append root "/klippy/.version")
                  (lambda (port) (display #$version port) (newline port)))
                (mkdir-p bin)
                (let ((python-wrapper (string-append bin "/klipper-python")))
                  ;; Make Python's Guix dependencies available to both Klippy
                  ;; and the upstream flashing utilities outside a build shell.
                  (call-with-output-file python-wrapper
                    (lambda (port)
                      (format port "#!/bin/sh~%exec ~s \"$@\"~%" python)))
                  (chmod python-wrapper #o755)
                  (wrap-program python-wrapper
                    `("GUIX_PYTHONPATH" prefix (,python-path)))
                  ;; Upstream's SD-card script assumes ~/klippy-env; use the
                  ;; packaged interpreter and dependencies instead.
                  (substitute* (string-append root "/scripts/flash-sdcard.sh")
                    (("KLIPPY_ENV=.*")
                     (string-append "KLIPPY_ENV=\"" python-wrapper "\"\n"))))
                ;; Expose stable entry points without modifying Klipper's
                ;; source layout, which its scripts use for relative imports.
                (for-each
                 (lambda (entry)
                   (let ((file (string-append bin "/" (car entry))))
                     (call-with-output-file file
                       (lambda (port)
                         (format port "#!/bin/sh~%exec ~s ~s \"$@\"~%"
                                 (cdr entry)
                                 (string-append root
                                                (if (string=? (car entry) "klippy")
                                                    "/klippy/klippy.py"
                                                    "/scripts/flash-sdcard.sh")))))
                     (chmod file #o755)))
                 `(("klippy" . ,(string-append bin "/klipper-python"))
                   ("klipper-flash-sdcard" . ,(which "bash"))))))))))
    (inputs (list python python-cffi python-greenlet python-jinja2
                  python-pyserial python-can python-setuptools))
    (home-page "https://www.klipper3d.org/")
    (synopsis "Host software and tools for Klipper 3D printer firmware")
    (description
     "Klipper runs printer control software on a Linux host and communicates
with firmware on one or more printer microcontrollers.  This package provides
Klippy, its upstream source and MCU firmware build and flashing scripts.")
    (license license:gpl3+)))
