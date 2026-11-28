;; A fresh source-only Go library and a dependent package containing two commands.
;; Build from the channel checkout:
;;   guix build -L modules --system=armhf-linux --no-substitutes \
;;     -f tests/runtime/go-cross.scm
;; Both out/bin/greet and out/bin/second must run and report linux/arm.
;; Repeat with --system=aarch64-linux for linux/arm64.
(use-modules (guix build-system go)
             (guix gexp)
             (guix packages)
             (guix utils)
             (spartan packages go)
             (spartan system build-policy))

(define (fixture-source directory)
  (local-file (canonicalize-path
               (string-append (dirname (current-filename)) "/go-cross/" directory))
              #:recursive? #t))

(define library
  (package
    ;; The pinned Go builder discovers source dependencies by their go- prefix.
    (name "go-spartan-cross-library-fixture")
    (version "1")
    (source (fixture-source "library"))
    (build-system go-build-system)
    (arguments (list #:import-path "example.org/spartan/greeting"
                     #:substitutable? #f))
    (home-page "https://example.org")
    (synopsis "Go cross-build library fixture")
    (description "A source-only library with no external Go dependencies.")
    (license #f)))

(define commands
  (package
    (inherit library)
    (name "spartan-go-cross-commands-fixture")
    (source (fixture-source "commands"))
    (arguments (list #:import-path "example.org/spartan/commands/..."
                     #:unpack-path "example.org/spartan/commands"
                     #:install-source? #f #:substitutable? #f))
    (propagated-inputs (list library))))

;; Explicit test-only selection: the production policy selects Node Exporter.
(define fixed-commands (go-with-cross-install commands))
(build-policy-package
 (make-build-policy #:system (%current-system) #:mixed-packages (list fixed-commands))
 fixed-commands)
