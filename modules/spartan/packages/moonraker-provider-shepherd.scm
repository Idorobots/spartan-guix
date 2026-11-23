;; SPDX-License-Identifier: MIT
(define-module (spartan packages moonraker-provider-shepherd)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages python-build)
  #:use-module (guix build-system pyproject)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages))

(define management-helper
  (with-extensions (list shepherd guile-json-4)
    (program-file
     "moonraker-shepherd"
     #~(begin
         ;; Resolve the installed executable, including profile symlinks and
         ;; the Python build system's wrapper, to locate its own module data.
         (load (string-append
                (dirname (dirname (canonicalize-path (car (command-line)))))
                "/share/moonraker-provider-shepherd/scheme/moonraker/shepherd.scm"))
         (exit ((module-ref (resolve-interface '(moonraker shepherd)) 'main)
                (cdr (command-line))))))))

(define-public moonraker-provider-shepherd
  (package
    (name "moonraker-provider-shepherd")
    (version "0.1.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/Idorobots/moonraker-provider-shepherd.git")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "1wzdjjbv2gxzk7608yh7lvl2kj7866ilwwbk78x4nkdzpjlzjpv3"))))
    (build-system pyproject-build-system)
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          (replace 'check
            (lambda* (#:key tests? #:allow-other-keys)
              (when tests?
                (setenv "PYTHONDONTWRITEBYTECODE" "1")
                (setenv "GUILE_AUTO_COMPILE" "0")
                (invoke "python" "-m" "unittest" "discover" "-s" "tests"
                        "-p" "test_*.py" "-v")
                (invoke "guile" "-L" "scheme" "tests/helper.scm")
                (invoke "python" "tests/integration.py"))))
          ;; Moonraker supplies BaseProvider in the consuming package. Adding
          ;; it here would create a cycle for patched Moonraker. Upstream CI
          ;; verifies imports and the real Moonraker HTTP API separately.
          (delete 'sanity-check)
          (add-after 'install 'install-management-helper
            (lambda _
              (mkdir-p (string-append #$output "/bin"))
              (copy-file #$management-helper
                         (string-append #$output "/bin/moonraker-shepherd"))
              (chmod (string-append #$output "/bin/moonraker-shepherd") #o555)))
          (add-after 'check 'check-installed-helper
            (lambda* (#:key tests? #:allow-other-keys)
              (when tests?
                (invoke (string-append #$output "/bin/moonraker-shepherd")
                        (string-append (getcwd) "/examples/policy.scm")
                        "capabilities")))))))
    (native-inputs (list bash coreutils python-setuptools guile-3.0
                         guile-json-4 shepherd))
    (home-page "https://github.com/Idorobots/moonraker-provider-shepherd")
    (synopsis "GNU Shepherd machine provider for Moonraker")
    (description
     "This package provides a Moonraker machine provider for GNU Shepherd.
It reports service state, manages explicitly permitted services, and requests
orderly shutdown or reboot through a policy-limited Guile helper.  It includes
the compatibility patch required by Moonraker 0.11.0.")
    (license license:expat)))
