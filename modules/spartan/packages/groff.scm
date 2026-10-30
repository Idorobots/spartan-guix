(define-module (spartan packages groff)
  #:use-module (gnu packages groff)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (groff/cross-fixed
            groff-minimal/cross-fixed
            package-with-cross-fixed-groff))

(define (groff-with-cross-fix base)
  (package
    (inherit base)
    (arguments
     (if (%current-target-system)
         (substitute-keyword-arguments (package-arguments base)
           ((#:make-flags _ '())
            #~(let ((native #+(if (string=? (package-name base) "groff-minimal")
                                 (lookup-package-native-input base "groff")
                                 (lookup-package-native-input base "self"))))
                (list (string-append "GROFF_BIN_PATH=" native "/bin")
                      (string-append "GROFFBIN=" native "/bin/groff")
                      (string-append "PDFMOMBIN=" native "/bin/pdfmom"))))
           ((#:phases phases)
            #~(modify-phases #$phases
                (add-after 'unpack 'use-native-documentation-commands
                  (lambda _
                    ;; pdfmom uses GROFF_COMMAND rather than GROFFBIN.  Its
                    ;; default test-groff wrapper executes target binaries.
                    (substitute* "Makefile.in"
                      (("GROFF_COMMAND=test-groff")
                       "GROFF_COMMAND=\"$(GROFFBIN)\"")))))))
         (package-arguments base)))))

(define groff/cross-fixed (groff-with-cross-fix groff))
(define groff-minimal/cross-fixed (groff-with-cross-fix groff-minimal))

(define package-with-cross-fixed-groff
  (package-input-rewriting
   `((,groff . ,groff/cross-fixed)
     (,groff-minimal . ,groff-minimal/cross-fixed))
   #:deep? #f))
