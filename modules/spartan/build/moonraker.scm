(define-module (spartan build moonraker)
  #:use-module (guix build utils)
  #:export (initialize-moonraker-state))

(define (initialize-moonraker-state data klipper-state uid gid)
  ;; Moonraker and Klippy share the klipper identity.  Keep writable data
  ;; separate from the declarative Moonraker configuration in the store.
  (let ((config (string-append data "/config")))
    (when (and (file-exists? config)
               (not (eq? 'symlink (stat:type (lstat config)))))
      (error "Moonraker config path already contains unmanaged data" config))
    (for-each
     (lambda (directory)
       (mkdir-p directory)
       (chown directory uid gid)
       (chmod directory #o750))
     (map (lambda (suffix) (string-append data suffix))
          '("" "/logs" "/gcodes" "/comms" "/database")))
    ;; This may be dangling until Klipper's activation creates its state.
    ;; Reconfiguration switches only the link and preserves all printer files.
    (switch-symlinks config klipper-state)))
