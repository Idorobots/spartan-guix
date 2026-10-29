(define-module (spartan packages compression)
  #:use-module (gnu packages check)
  #:use-module (gnu packages compression)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (libcbor/cross-fixed
            package-with-cross-fixed-libcbor))

(define libcbor/cross-fixed
  ;; Guix ebba73d4 enabled libcbor's tests with CMocka in native-inputs.
  ;; The tests link against CMocka, so cross-builds need the target library,
  ;; not the build machine's library.  CMake's cross build system already
  ;; skips test execution; retain upstream's test compilation and native recipe.
  (package
    (inherit libcbor)
    (native-inputs
     (if (%current-target-system)
         (modify-inputs (package-native-inputs libcbor)
           (delete "cmocka"))
         (package-native-inputs libcbor)))
    (inputs
     (if (%current-target-system)
         (modify-inputs (package-inputs libcbor)
           (prepend cmocka))
         (package-inputs libcbor)))))

(define package-with-cross-fixed-libcbor
  ;; Rewrite explicit dependencies such as OpenSSH -> libfido2 -> libcbor,
  ;; without changing the implicit build-tool dependency graph.
  (package-input-rewriting
   `((,libcbor . ,libcbor/cross-fixed))
   #:deep? #f))
