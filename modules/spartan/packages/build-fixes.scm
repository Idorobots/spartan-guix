(define-module (spartan packages build-fixes)
  #:use-module ((gnu packages gettext) #:select (gettext-minimal))
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix platform)
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
   ((and (%current-target-system)
         (is? "python-setuptools-bootstrap" "80.9.0"))
    ;; The GNU bootstrap phases run "python setup.py", but upstream provides
    ;; python-wrapper only as a target input.  Cross builds need an interpreter
    ;; on the build machine's PATH as well.  Reuse the recipe's Python version.
    (package/inherit base
      (native-inputs
       (cons (list "python" (lookup-package-input base "python-wrapper"))
             (package-native-inputs base)))))
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
   ((and (%current-target-system)
         (or armhf? (string=? system "aarch64-linux"))
         (is? "glib" "2.86.0")
         (lookup-package-native-input base "gobject-introspection"))
    ;; The full GLib must provide GIRs to native consumers such as Poppler.
    ;; Upstream silently omits them when Meson cannot run target binaries.
    ;; The bootstrap GLib deliberately has no introspection dependency.
    (package/inherit base
      (inputs
       (cons (list "gobject-introspection"
                   (@@ (gnu packages glib) gobject-introspection-minimal))
             (package-inputs base)))
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:configure-flags flags #~'())
          #~(append (list "-Dlibdir=lib" "-Dintrospection=enabled" "-Dtests=false"
                          "--cross-file=../glib-introspection.ini")
                    #$flags))
         ((#:phases phases #~%standard-phases)
          #~(modify-phases #$phases
              (add-before 'configure 'enable-cross-introspection
                (lambda* (#:key inputs #:allow-other-keys)
                  ;; The opted-in image build already requires transparent
                  ;; target execution.  Only GIR probes need it here; Meson's
                  ;; compiler commands remain those of the Guix cross file.
                  ;; Both the source and build directories are under this root.
                  (call-with-output-file "../glib-introspection.ini"
                    (lambda (port)
                      (display "[properties]\nneeds_exe_wrapper = false\n" port)))
                  ;; The native scanner's ldd would select the runner's loader.
                  ;; Resolve target shared libraries with the target loader.
                  (let ((wrapper (string-append (getcwd) "/cross-gir-ldd"))
                        (loader (search-input-file
                                 inputs
                                 #$(platform-glibc-dynamic-linker
                                    (lookup-platform-by-target
                                     (%current-target-system))))))
                    (call-with-output-file wrapper
                      (lambda (port)
                        (format port "#!~a\nexec ~s --list \"$@\"\n"
                                (which "sh") loader)))
                    (chmod wrapper #o755)
                    (substitute* "meson.build"
                      (("gir_args = \\[")
                       (string-append "gir_args = ['--use-ldd-wrapper="
                                      wrapper "',"))))))))))))
   ((and armhf? (is? "glib" "2.86.0"))
    (package/inherit base
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ;; Retain the libdir correction alongside the test fallback.
         ((#:configure-flags flags #~'()) #~(cons "-Dlibdir=lib" #$flags))
         ((#:phases phases #~%standard-phases)
          #~(modify-phases #$phases
              (add-after 'disable-failing-tests 'skip-qemu-incompatible-tests
                (lambda _
                  ;; QEMU user emulation cannot provide the native RLIMIT_NPROC
                  ;; failure semantics or ptrace support these subtests require.
                  ;; Keep the remaining thread, thread-pool and subprocess tests.
                  (substitute* '("glib/tests/thread.c"
                                 "glib/tests/thread-pool.c"
                                 "gio/tests/gsubprocess.c")
                    (("[ \t]*g_test_add_func.*\"/(thread/thread4|thread_pool/pool_fail|gsubprocess/exit-status/trapped)\".*;")
                     ""))))))))))
   ((is? "gobject-introspection" "1.86.0")
    (package/inherit base
      (native-inputs
       (if (%current-target-system)
           ;; Meson's Python >= 3.12 probe imports setuptools on the build
           ;; machine.  Target propagated inputs are not on its module path.
           ;; Retain the recipe's bootstrap/full variant to avoid a cycle.
           (cons (list "python-setuptools-bootstrap"
                       (lookup-package-propagated-input
                        base "python-setuptools-bootstrap"))
                 (package-native-inputs base))
           (package-native-inputs base)))
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:configure-flags flags #~'()) #~(cons "-Dlibdir=lib" #$flags))))))
   ((or (is? "harfbuzz" "11.4.4")
        (is? "cairo" "1.18.4")
        (and armhf?
             (or (is? "linux-pam" "1.7.2")
                 (is? "dbus" "1.16.2"))))
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
