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

(define (path-type path)
  (catch 'system-error
    (lambda () (stat:type (lstat path)))
    (lambda args
      (if (= ENOENT (system-error-errno args)) #f (apply throw args)))))

(define (seed-klipper-config state seed)
  (let loop ((directory state) (parts (string-split (car seed) #\/)))
    (let* ((path (string-append directory "/" (car parts)))
           (type (path-type path)))
      (if (null? (cdr parts))
          (case type
            ((regular) #t)
            ((#f)
             (let* ((port (mkstemp! (string-append directory "/.klipper-seed-XXXXXX") "wb"))
                    (temporary (port-filename port)))
               (dynamic-wind
                 (const #t)
                 (lambda ()
                   (call-with-input-file (cdr seed)
                     (lambda (input) (dump-port input port)) #:binary #t)
                   (chmod port #o640)
                   (close-port port)
                   ;; Publish the complete file without replacing a concurrent edit.
                   (catch 'system-error
                     (lambda () (link temporary path))
                     (lambda args
                       (unless (and (= EEXIST (system-error-errno args))
                                    (eq? 'regular (path-type path)))
                         (apply throw args)))))
                 (lambda ()
                   (unless (port-closed? port) (close-port port))
                   (delete-file temporary)))))
            (else (error "Klipper configuration destination is not a regular file" path)))
          (begin
            (case type
              ((directory) #t)
              ((#f) (mkdir path #o750))
              (else (error "Klipper configuration parent is not a directory" path)))
            (loop path (cdr parts)))))))

(define (call-as-klipper uid gid thunk)
  ;; Configuration directories are writable by Klipper and Moonraker. Never
  ;; traverse them as root when seeding, even if a path changes after lstat.
  (if (and (= uid (geteuid)) (= gid (getegid)))
      (thunk)
      (let ((saved-uid (geteuid)) (saved-gid (getegid)) (groups (getgroups)))
        (dynamic-wind
          (const #t)
          (lambda ()
            (setgroups #())
            (setegid gid)
            (seteuid uid)
            (thunk))
          (lambda ()
            (seteuid saved-uid)
            (setegid saved-gid)
            (setgroups groups))))))

(define* (initialize-klipper-state state run seeds uid gid
                                    #:key firmware-source)
  (for-each (lambda (directory)
              (mkdir-p directory)
              (chown directory uid gid)
              (chmod directory #o750))
            (list state run))
  (call-as-klipper uid gid
    (lambda () (for-each (lambda (seed) (seed-klipper-config state seed)) seeds)))
  (when firmware-source
    (initialize-klipper-firmware firmware-source
                                 (string-append run "/firmware") uid gid)))
