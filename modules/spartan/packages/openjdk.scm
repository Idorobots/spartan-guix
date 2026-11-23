;; SPDX-License-Identifier: MIT
(define-module (spartan packages openjdk)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages nss)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (openjdk-armhf))

;; Debian trixie's armhf JDK 25 is built with the Zero interpreter (no JIT).
;; OpenJDK 21 is the newest armhf build with HotSpot, so prefer it here.
(define %openjdk-debian-version "21.0.13+9-1~deb13u2")

(define-public openjdk-armhf
  (package
    (name "openjdk")
    (version "21.0.13")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://deb.debian.org/debian/pool/main/o/openjdk-21/"
             "openjdk-21-jre-headless_"
             %openjdk-debian-version "_armhf.deb"))
       (file-name "openjdk-21-jre-headless-armhf.deb")
       (sha256
        (base32 "0k7dyranyzqs09ssr3irnzz29bmwi6xkmhw32z8ji1pr4nn4n68d"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out (assoc-ref %outputs "out"))
                 (source (assoc-ref %build-inputs "source"))
                 (binutils (assoc-ref %build-inputs "binutils"))
                 (tar (assoc-ref %build-inputs "tar"))
                 (xz (assoc-ref %build-inputs "xz"))
                 (zstd (assoc-ref %build-inputs "zstd"))
                 (bash (assoc-ref %build-inputs "bash"))
                 (patchelf (assoc-ref %build-inputs "patchelf"))
                 (glibc (assoc-ref %build-inputs "glibc"))
                 (gcc-lib (assoc-ref %build-inputs "gcc:lib"))
                 (zlib (assoc-ref %build-inputs "zlib"))
                 (nss-certs (assoc-ref %build-inputs "nss-certs"))
                 (jre "usr/lib/jvm/java-21-openjdk-armhf")
                 (rpath
                  (string-join
                   (list "$ORIGIN"
                         "$ORIGIN/.."
                         "$ORIGIN/../lib"
                         "$ORIGIN/server"
                         (string-append glibc "/lib")
                         (string-append gcc-lib "/lib")
                         (string-append zlib "/lib"))
                   ":"))
                 (interpreter (string-append glibc
                                             "/lib/ld-linux-armhf.so.3")))
            ;; A .deb is an ar archive containing data.tar.{xz,zst}.
            (invoke (string-append binutils "/bin/ar") "x" source)
            (let* ((data (car (find-files "." "^data\\.tar\\.")))
                   (decompressor
                    (if (string-suffix? ".xz" data)
                        (string-append xz "/bin/xz -dc")
                        (string-append zstd "/bin/zstd -dc")))
                   (status
                    (system* (string-append bash "/bin/bash") "-c"
                             (string-append decompressor " "
                                            (object->string data) " | "
                                            tar "/bin/tar xf -"))))
              (unless (zero? status)
                (error "failed to extract the Debian data tarball")))

            (copy-recursively jre out)
            (copy-recursively "etc/java-21-openjdk"
                              (string-append out "/etc/java-21-openjdk"))

            ;; The Debian package points its configuration at /etc.  Replace
            ;; those absolute symlinks with real copies so the JRE is fully
            ;; self-contained in the store and does not depend on host /etc.
            (for-each (lambda (file)
                        (let ((target (readlink file)))
                          (when (string-prefix? "/etc/java-21-openjdk/" target)
                            (let ((source (string-append out target)))
                              (delete-file file)
                              (copy-file source file)))))
                      (find-files out
                                  (lambda (file stat)
                                    (symbolic-link? file))))

            ;; The Debian package links cacerts to /etc; drop it here so the
            ;; ELF scan does not follow a dangling link.  It is regenerated
            ;; below from Guix's CA bundle.
            (let ((cacerts (string-append out "/lib/security/cacerts")))
              (when (or (file-exists? cacerts) (symbolic-link? cacerts))
                (delete-file cacerts)))

            ;; Drop the dangling documentation symlink as well.
            (let ((docs (string-append out "/docs")))
              (when (or (file-exists? docs) (symbolic-link? docs))
                (delete-file docs)))

            ;; The JVM only needs the core runtime libraries.  Drop the
            ;; optional smart-card and PKCS#11 providers so the JRE does not
            ;; depend on the much heavier NSS/PC-SC stack.
            (substitute* (string-append out
                                        "/etc/java-21-openjdk/security/java.security")
              (("^security\\.provider\\.9=SunPCSC\n" all) "")
              (("^security\\.provider\\.12=SunPKCS11\n" all) ""))

            ;; Point every ELF object at the Guix runtime libraries.
            (for-each (lambda (file)
                        (when (elf-file? file)
                          (invoke (string-append patchelf "/bin/patchelf")
                                  "--set-rpath" rpath file)))
                      (find-files out))

            ;; Helpers and launchers need the Guix dynamic loader.
            (for-each (lambda (file)
                        (when (and (file-exists? file) (elf-file? file))
                          (invoke (string-append patchelf "/bin/patchelf")
                                  "--set-interpreter" interpreter file)))
                      (append (find-files (string-append out "/bin"))
                              (list (string-append out "/lib/jexec")
                                    (string-append out "/lib/jspawnhelper"))))

            ;; Build the default trust store from Guix's CA bundle.
            (let ((cacerts (string-append out "/lib/security/cacerts")))
              (when (file-exists? cacerts)
                (delete-file cacerts))
              (for-each (lambda (cert)
                          (invoke (string-append out "/bin/keytool")
                                  "-import" "-noprompt"
                                  "-storetype" "JKS"
                                  "-alias" (basename cert)
                                  "-keystore" cacerts
                                  "-storepass" "changeit"
                                  "-file" cert))
                        (find-files (string-append nss-certs
                                                   "/etc/ssl/certs")
                                    "\\.pem$")))
            #t))))
    (inputs
     `(("glibc" ,glibc)
       ("gcc:lib" ,gcc "lib")
       ("zlib" ,zlib)))
    (native-inputs
     `(("bash" ,bash)
       ("binutils" ,binutils)
       ("tar" ,tar)
       ("xz" ,xz)
       ("zstd" ,zstd)
       ("patchelf" ,patchelf)
       ("nss-certs" ,nss-certs)))
    (supported-systems '("armhf-linux"))
    (home-page "https://openjdk.org/")
    (synopsis "OpenJDK 21 runtime for 32-bit ARM")
    (description
     "Prebuilt OpenJDK 21 headless runtime from Debian, repackaged for Guix on
armhf.  It avoids building the full OpenJDK boot-JDK chain from source on the
Raspberry Pi 2 while keeping the JVM and Java tooling available in the store.")
    (license license:gpl2+)))
