;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; Reusable PSplash boot-splash service.
;;;
;;; psplash draws on the framebuffer and then blocks, listening on a FIFO for
;;; progress updates and for the QUIT command.  This module runs it as early as
;;; the framebuffer is available and provides a one-shot psplash-quit service
;;; (plus the psplash-quit-command program) so a display manager can ask it to
;;; exit just before the graphical session takes over the framebuffer.

(define-module (spartan services psplash)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (spartan packages psplash)
  #:export (psplash-service-type
            psplash-configuration
            psplash-configuration?
            psplash-configuration-psplash
            psplash-configuration-fifo-directory
            psplash-quit-command))

(define-record-type* <psplash-configuration>
  psplash-configuration make-psplash-configuration
  psplash-configuration?
  (psplash psplash-configuration-psplash (default psplash))
  (fifo-directory psplash-configuration-fifo-directory (default "/run")))

(define* (psplash-quit-command #:key (psplash psplash) (fifo-directory "/run"))
  "Return a program that asks a running @command{psplash} to exit through its
FIFO.  Use it in a session command or a one-shot service ordered before a
display manager."
  (program-file
   "psplash-quit"
   #~(begin
       (setenv "PSPLASH_FIFO_DIR" #$fifo-directory)
       (execl #$(file-append psplash "/bin/psplash-write")
              "psplash-write" "QUIT"))))

(define (psplash-shepherd-services config)
  (let ((psplash (psplash-configuration-psplash config))
        (fifo-directory (psplash-configuration-fifo-directory config)))
    (list
     (shepherd-service
      (documentation "Draw the PSplash boot image on the framebuffer.")
      (provision '(psplash))
      (requirement '(file-systems))
      ;; psplash stays resident until told to quit; do not restart it.
      (respawn? #f)
      (start #~(make-forkexec-constructor
                (list #$(file-append psplash "/bin/psplash"))
                ;; Keep psplash's own diagnostics (e.g. VT/FB errors) off the
                ;; console; inspect /run/psplash.log instead.
                #:log-file "/run/psplash.log"
                #:environment-variables
                (list #$(string-append "PSPLASH_FIFO_DIR=" fifo-directory))))
      (stop #~(make-kill-destructor)))
     (shepherd-service
      (documentation "Ask a running PSplash to exit, for example before a display manager starts.")
      (provision '(psplash-quit))
      (one-shot? #t)
      ;; Only run when a consumer (a display manager) requires it.
      (auto-start? #f)
      (start #~(lambda _
                 ;; Best effort: psplash may already be gone.
                 (system* #$(psplash-quit-command #:psplash psplash
                                                  #:fifo-directory fifo-directory))
                 #t))))))

(define psplash-service-type
  (service-type
   (name 'psplash)
   (extensions
    (list (service-extension shepherd-root-service-type
                             psplash-shepherd-services)))
   (default-value (psplash-configuration))
   (description "Run PSplash on the framebuffer from early boot until a display
manager takes over the display.  Add the @code{psplash-quit} provision to a
display manager's Shepherd requirements (for example greetd's
@code{extra-shepherd-requirement}) so the splash exits before the graphical
session starts.")))
