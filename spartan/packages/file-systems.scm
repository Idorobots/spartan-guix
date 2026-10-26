(define-module (spartan packages file-systems)
  #:use-module (gnu packages file-systems)
  #:use-module (guix packages)
  #:export (bcachefs-tools/cross-fixed))

(define bcachefs-tools/cross-fixed
  ;; Guix f519ddf mixes labelled inputs with a bare bcachefs-tools-minimal
  ;; package when cross-compiling. Label that helper without dropping it or
  ;; changing native builds. The stock resize service references these tools
  ;; even for ext4. Remove the workaround once the pinned Guix fixes the input.
  (package
    (inherit bcachefs-tools)
    (native-inputs
     (map (lambda (input)
            (if (package? input)
                (list (package-name input) input)
                input))
          (package-native-inputs bcachefs-tools)))))
