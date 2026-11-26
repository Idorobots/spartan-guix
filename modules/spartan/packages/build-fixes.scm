(define-module (spartan packages build-fixes)
  #:use-module ((gnu packages gettext) #:select (gettext-minimal))
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages go)
  #:export (package-build-fix))

;; Source-build fallbacks for Guix 2bc642182.  These procedures do no store I/O:
;; the build policy checks the original candidate before calling them.
(define (package-build-fix base system)
  (define (is? name version)
    (and (string=? (package-name base) name)
         (string=? (package-version base) version)))
  (define armhf? (string=? system "armhf-linux"))
  (cond
   ((and (%current-target-system)
         (is? "prometheus-node-exporter" "1.10.2"))
    (go-with-cross-install base))
   ((is? "guile-avahi" "0.4.1")
    ;; Every test requires an external, already-running Avahi daemon.
    (package/inherit base
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:tests? _ #t) #f)))))
   ((is? "poppler" "26.07.0")
    ;; The translation update target invokes xgettext.
    (package/inherit base
      (native-inputs (cons (list "gettext" gettext-minimal)
                           (package-native-inputs base)))))
   ((or (is? "harfbuzz" "11.4.4")
        (is? "cairo" "1.18.4")
        (is? "gobject-introspection" "1.86.0")
        (and armhf?
             (or (is? "linux-pam" "1.7.2")
                 (is? "dbus" "1.16.2")
                 (is? "glib" "2.86.0"))))
    ;; Meson's host-dependent lib64 default disagrees with Guix's RUNPATH.
    (package/inherit base
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:configure-flags flags #~'()) #~(cons "-Dlibdir=lib" #$flags))))))
   ((is? "sudo" "1.9.17p1")
    (package/inherit base
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:configure-flags flags #~'())
          #~(cons "--enable-tmpfiles.d=/tmp/dummy" #$flags))))))
   ((string=? (package-name base) "guile-ssh")
    (package/inherit base
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:parallel-tests? _ #t) #f)))))
   ((and armhf? (is? "elogind" "257.14"))
    ;; User-mode ARM emulation cannot faithfully implement these clone tests.
    (package/inherit base
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:phases phases #~%standard-phases)
          #~(modify-phases #$phases
              (add-after 'unpack 'skip-qemu-incompatible-tests
                (lambda _
                  (substitute* '("src/test/test-process-util.c"
                                 "src/test/test-raw-clone.c")
                    (("DEFINE_TEST_MAIN_WITH_INTRO\\(LOG_INFO, intro\\);")
                     "int main(void) { return 77; }")
                    (("DEFINE_TEST_MAIN\\(LOG_INFO\\);")
                     "int main(void) { return 77; }"))))))))))
   ((and armhf? (is? "libgpg-error" "1.61"))
    ;; ARM hard float has no wider long double: LDBL_MAX equals DBL_MAX.
    (package/inherit base
      (source
       (origin (inherit (package-source base))
         (patches
          (append (origin-patches (package-source base))
                  (list (local-file
                         (canonicalize-path
                          (search-path %load-path
                                       "spartan/patches/libgpg-error-armhf-t-printf.patch"))))))))))
   ((and armhf? (is? "python-trio" "0.33.0"))
    (package/inherit base
      (source
       (origin (inherit (package-source base))
         (patches
          (append (origin-patches (package-source base))
                  (list (local-file
                         (canonicalize-path
                          (search-path %load-path
                                       "spartan/patches/python-trio-socket-capabilities.patch"))))))))))
   (else base)))
