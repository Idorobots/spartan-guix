(define-module (spartan packages gtk)
  #:use-module (gnu packages gtk)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (pango/cross-fixed
            package-with-cross-fixed-pango))

(define pango/cross-fixed
  (package
    (inherit pango)
    (native-inputs
     (if (%current-target-system)
         (modify-inputs (package-native-inputs pango)
           (delete "gobject-introspection"))
         (package-native-inputs pango)))
    (arguments
     (if (%current-target-system)
         (substitute-keyword-arguments (package-arguments pango)
           ((#:configure-flags flags #~'())
            #~(cons "-Dintrospection=disabled"
                    (filter (lambda (flag)
                              (not (string-prefix? "-Dintrospection=" flag)))
                            #$flags))))
         (package-arguments pango)))))

(define package-with-cross-fixed-pango
  ;; Consumers here use the C libraries, not GObject language bindings.
  (package-input-rewriting
   `((,pango . ,pango/cross-fixed))
   #:deep? #f))
