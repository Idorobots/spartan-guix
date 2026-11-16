(define-module (spartan build klipper)
  #:use-module (guix build utils)
  #:export (initialize-klipper-state))

(define (initialize-klipper-firmware source directory uid gid)
  ;; Reconfiguration must not discard an in-progress build.  /run is cleared
  ;; at boot, so the next boot naturally picks up the installed package again.
  (unless (file-exists? directory)
    (let ((staging (mkdtemp (string-append directory ".XXXXXX"))))
      (dynamic-wind
        (const #t)
        (lambda ()
          ;; Publish only a complete copy, so a failed activation can retry.
          (unless (copy-recursively source staging #:log (%make-void-port "w"))
            (error "Failed to prepare Klipper firmware workspace" source))
          (for-each
           (lambda (file)
             (chown file uid gid)
             ;; Store files are read-only; retain executable bits but allow
             ;; the workspace owner to edit sources and build configuration.
             (chmod file (logior #o200 (stat:perms (lstat file)))))
           (find-files staging
                       (lambda (file stat) (not (eq? 'symlink (stat:type stat))))
                       #:directories? #t))
          (chmod staging #o750)
          (rename-file staging directory))
        (lambda ()
          (when (file-exists? staging)
            (delete-file-recursively staging)))))))

(define* (initialize-klipper-state state run seed uid gid
                                   #:key firmware-source)
  (let ((config-file (string-append state "/printer.cfg")))
    (for-each (lambda (directory)
                (mkdir-p directory)
                (chown directory uid gid)
                (chmod directory #o750))
              (list state run))
    (unless (file-exists? config-file)
      (copy-file seed config-file)
      (chown config-file uid gid)
      (chmod config-file #o640))
    (when firmware-source
      (initialize-klipper-firmware firmware-source
                                   (string-append run "/firmware") uid gid))))
