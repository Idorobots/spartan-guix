;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; PSplash is a small userspace boot splash from the Yocto Project.  It draws
;;; a PNG (compiled into the binary as a gdk-pixbuf C array) and an optional
;;; progress bar directly on the framebuffer, and exposes psplash-write for
;;; progress updates.  The image is baked in at build time; a custom splash is
;;; supplied by overriding base-images/psplash-poky.png when this package is
;;; customized.

(define-module (spartan packages psplash)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages pkg-config)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (psplash
            psplash-with-image))

(define %psplash-commit "53ae74a36bf17675228552abb927d2f981940a6a")

(define-public psplash
  (package
    (name "psplash")
    (version (git-version "0.1" "0" %psplash-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://git.yoctoproject.org/psplash")
             (commit %psplash-commit)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0pcqf4zn64xcq7yl8bp73xraa4rxcrwb7y4hgp0d8smlkmdh9hqi"))))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; Do not print the banner to the console before the image appears.
      #:configure-flags #~'("--disable-startup-msg")
      #:phases
      #~(modify-phases %standard-phases
          ;; The tarball ships only configure.ac/Makefile.am.
          (add-before 'configure 'autoreconf
            (lambda _
              (invoke "autoreconf" "-vfi"))))))
    ;; gdk-pixbuf supplies gdk-pixbuf-csource, used by make-image-header.sh to
    ;; turn base-images/*.png into the C headers the build compiles in.
    (native-inputs (list autoconf automake gdk-pixbuf pkg-config))
    (home-page "https://git.yoctoproject.org/psplash")
    (synopsis "Lightweight framebuffer boot splash screen")
    (description
     "PSplash is a userspace graphical boot splash screen for embedded Linux
devices with a 16bpp or 32bpp framebuffer.  It draws a compiled-in image and a
progress bar directly on the framebuffer and ships @command{psplash-write}, a
client utility for reporting progress.  Its only runtime dependency is libc.")
    (license license:gpl2+)))

(define* (psplash-with-image image #:key (base psplash) (fullscreen? #t))
  "Return a PSplash variant that bakes IMAGE, a PNG file-like, as the splash
drawn on the framebuffer.  With FULLSCREEN? (the default) the image is centered
and may be a full-panel picture; otherwise it is placed above the progress bar,
which is the upstream layout.  A custom image should match the framebuffer
orientation and size reported by the kernel (for example 720x1280 on the Seeed
panel)."
  ;; The condition is fixed when the package is defined, so splice the flag in.
  (let ((extra-flags (if fullscreen? '("--enable-img-fullscreen") '())))
    (package
      (inherit base)
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:configure-flags flags #~'())
          #~(append #$flags (list #$@extra-flags)))
         ((#:phases phases #~%standard-phases)
          #~(modify-phases #$phases
              ;; make-image-header.sh compiles base-images/psplash-poky.png into
              ;; the binary at build time, so replace it before the build.
              (add-after 'unpack 'replace-splash-image
                (lambda _
                  (copy-file #$image "base-images/psplash-poky.png"))))))))))
