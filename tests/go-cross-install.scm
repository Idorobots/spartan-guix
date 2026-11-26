(use-modules (gnu packages monitoring)
             ((guix build go-build-system) #:prefix build:)
             (guix build utils)
             (guix build-system)
             (guix build-system go)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (guix utils)
             (ice-9 textual-ports)
             (spartan packages build-fixes)
             (spartan packages go)
             (spartan packages mixed)
             (spartan system build-policy)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "go-cross-install")
(define %standard-phases build:%standard-phases)

(define* (argument p key #:optional (default #f))
  (keyword-argument (package-arguments p) key default))

(define* (keyword-argument args key #:optional (default #f))
  (let loop ((args args))
    (cond ((null? args) default)
          ((eq? (car args) key) (cadr args))
          (else (loop (cddr args))))))

(define (cross-phases target)
  (parameterize ((%current-system "x86_64-linux") (%current-target-system target))
    (eval (gexp->approximate-sexp
           (keyword-argument
            (bag-arguments
             (package->bag (package-build-fix prometheus-node-exporter
                                             (gnu-triplet->nix-system target))
                           "x86_64-linux" target #:graft? #f))
            #:phases))
          (current-module))))

(for-each
 (lambda (system)
   (test-assert (string-append system ": native exporter retains the exact upstream recipe")
     (parameterize ((%current-system system) (%current-target-system #f))
       (eq? prometheus-node-exporter (package-build-fix prometheus-node-exporter system)))))
 '("x86_64-linux" "armhf-linux" "aarch64-linux"))

(with-store store
  (let ((fixed (go-with-cross-install prometheus-node-exporter)))
    (for-each
     (lambda (system)
       (parameterize ((%current-system system) (%current-target-system #f))
         (test-equal (string-append system ": the helper itself preserves the native derivation")
           (derivation-file-name
            (package-derivation store prometheus-node-exporter system #:graft? #f))
           (derivation-file-name (package-derivation store fixed system #:graft? #f)))))
     '("x86_64-linux" "armhf-linux" "aarch64-linux"))))

(test-assert "native security replacements retain their own custom Go lowerer"
  (let* ((security-bs
          (build-system
            (inherit go-build-system)
            (lower
             (lambda args
               (let ((lowered (apply (build-system-lower go-build-system) args)))
                 (bag (inherit lowered)
                   (arguments
                    (substitute-keyword-arguments (bag-arguments lowered)
                      ((#:build-flags flags #~'()) #~(cons "-tags=security" #$flags))))))))))
         (security-package (package (inherit prometheus-node-exporter)
                             (build-system security-bs)))
         (base (package (inherit prometheus-node-exporter) (replacement security-package)))
         (fixed (go-with-cross-install base)))
    (with-store store
      (string=?
       (derivation-file-name (package-derivation store security-package "x86_64-linux" #:graft? #f))
       (derivation-file-name
        (package-derivation store (package-replacement fixed) "x86_64-linux" #:graft? #f))))))

(test-assert "one reusable lowerer selects native, cross and native bags independently of parameters"
  (let ((fixed (go-with-cross-install prometheus-node-exporter)))
    (every
     (lambda (target)
       (parameterize ((%current-system "x86_64-linux") (%current-target-system #f))
         (let ((text (object->string
                      (bag-arguments (package->bag fixed "x86_64-linux" target #:graft? #f)))))
           (eq? (and target
                     (not (string=? "x86_64-linux" (gnu-triplet->nix-system target))))
                (and (string-contains text "allow-cross-go-install") #t)))))
     '(#f "arm-linux-gnueabihf" #f "aarch64-linux-gnu" #f "x86_64-linux-gnu"))))

(test-assert "the policy leaves unrelated Go packages unchanged during cross-compilation"
  (parameterize ((%current-system "x86_64-linux") (%current-target-system "arm-linux-gnueabihf"))
    (every
     (lambda (base)
       (let* ((fixed (package-build-fix base "armhf-linux"))
              (bag (package->bag fixed "x86_64-linux" "arm-linux-gnueabihf" #:graft? #f)))
         (and (eq? base fixed)
              (not (string-contains (object->string (bag-arguments bag))
                                    "allow-cross-go-install")))))
     (list (package (inherit prometheus-node-exporter)
             (name "go-unrelated-library")
             (arguments (list #:import-path "example.org/library" #:skip-build? #t)))
           (package (inherit prometheus-node-exporter)
             (name "another-go-command"))))))

(test-assert "source-only recipes can remove build and setup phases"
  (every
   (lambda (phases)
     (let* ((base (package (inherit prometheus-node-exporter)
                    (name "go-source-only-fixture")
                    (arguments (list #:phases phases))))
            (fixed (go-with-cross-install base))
            (bag (package->bag fixed "x86_64-linux" "arm-linux-gnueabihf" #:graft? #f))
            (selected (eval (gexp->approximate-sexp
                             (keyword-argument (bag-arguments bag) #:phases))
                            (current-module))))
       (and (not (assq-ref selected 'build))
            (not (assq-ref selected 'install-cross-go-commands))
            (assq-ref selected 'install))))
   (list #~(modify-phases %standard-phases (delete 'build) (delete 'check))
         #~(list (cons 'install (lambda _ #t))))))

(for-each
 (lambda (target arch)
   (let ((phases (cross-phases target)))
     (test-assert (string-append arch ": upstream build, embed and test phases are retained")
       (every (lambda (name) (assq-ref phases name))
              '(build fix-embed-files pre-check check post-check install)))
     (test-assert (string-append arch ": only target commands are installed, with executable mode preserved")
       (call-with-temporary-directory
        (lambda (directory)
          (let* ((out (string-append directory "/out"))
                 (workspace (string-append directory "/workspace"))
                 (target-bin (string-append workspace "/bin/linux_" arch))
                 (binary (string-append target-bin "/node_exporter")))
            (mkdir-p target-bin)
            (call-with-output-file binary (lambda (port) (display "target command" port)))
            (chmod binary #o755)
            (call-with-output-file (string-append workspace "/bin/host-tool")
              (lambda (port) (display "build-machine command" port)))
            (with-environment-variables
                `(("GOBIN" ,(string-append out "/bin")) ("GOPATH" ,workspace)
                  ("GOOS" "linux") ("GOARCH" ,arch) ("GOARM" "7"))
              ((assq-ref phases 'allow-cross-go-install))
              ((assq-ref phases 'install-cross-go-commands) #:outputs `(("out" . ,out)))
              (let ((installed (string-append out "/bin/node_exporter")))
                (and (not (getenv "GOBIN"))
                     (string=? "7" (getenv "GOARM"))
                     (string=? "target command" (call-with-input-file installed get-string-all))
                     (= #o755 (stat:perms (stat installed)))
                     (not (file-exists? (string-append out "/bin/host-tool"))))))))))
     (test-assert (string-append arch ": missing command directories do not break library-only builds")
       (call-with-temporary-directory
        (lambda (directory)
          (with-environment-variables `(("GOPATH" ,directory) ("GOOS" "linux") ("GOARCH" ,arch))
            ((assq-ref phases 'install-cross-go-commands)
             #:outputs `(("out" . ,(string-append directory "/out"))))
            (not (file-exists? (string-append directory "/out/bin")))))))))
 '("arm-linux-gnueabihf" "aarch64-linux-gnu") '("arm" "arm64"))

(test-assert "the fallback preserves exporter version flags, embed files and source policy"
  (parameterize ((%current-system "x86_64-linux") (%current-target-system "arm-linux-gnueabihf"))
    (let ((fixed (package-build-fix prometheus-node-exporter "armhf-linux")))
      (every (lambda (key)
               (equal? (argument prometheus-node-exporter key) (argument fixed key)))
             '(#:build-flags #:embed-files #:install-source? #:import-path)))))

(for-each
 (lambda (available?)
   (test-assert (if available? "a native substitute hit bypasses the cross-only fix"
                             "a mixed-compilation miss selects the corrected cross phases")
     (parameterize (((@@ (spartan packages mixed) %native-outputs-available?) (const available?)))
       (let* ((policy (make-build-policy #:system "armhf-linux" #:build-system "x86_64-linux"
                                        #:mixed-packages (list prometheus-node-exporter)))
              (bag (package->bag (build-policy-package policy prometheus-node-exporter)
                                "armhf-linux" #f #:graft? #f))
              (text (object->string (bag-arguments bag))))
         (and (string=? (if available? "armhf-linux" "x86_64-linux") (bag-system bag))
              (equal? (if available? #f "arm-linux-gnueabihf") (bag-target bag))
              (eq? (not available?) (and (string-contains text "allow-cross-go-install") #t)))))))
 '(#t #f))

(define runner (test-runner-current))
(test-end "go-cross-install")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
