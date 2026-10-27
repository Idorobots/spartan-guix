;; Run with `guix repl ci/channels.scm` to emit a pure-data channel file for
;; Guix's isolated loader. The committed checkout supplies the channel under
;; test, including PR merge commits; no remote publication is needed.
(use-modules (guix channels) (ice-9 pretty-print))

(let* ((root (dirname (dirname (canonicalize-path (current-filename)))))
       (commit (or (getenv "SPARTAN_GUIX_COMMIT") (getenv "GITHUB_SHA"))))
  (unless commit
    (error "Set SPARTAN_GUIX_COMMIT to the checkout's git commit"))
  (pretty-print
   `(list ,@(map channel->code
                 (list (channel
                        (name 'spartan-guix)
                        (url (string-append "file://" root))
                        (branch "main")
                        (commit commit))
                       ;; Select CI's Guix version here. Runtime dependencies
                       ;; such as Nonguix are resolved from .guix-channel.
                       (channel
                        (name 'guix)
                        (url "https://git.guix.gnu.org/guix.git")
                        (commit "9873d2c433b7dc8e2d510fc437c5b13c98d0a4ff")
                        (introduction
                         (make-channel-introduction
                          "9edb3f66fd807b096b48283debdcddccfea34bad"
                          (openpgp-fingerprint
                           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))))))
