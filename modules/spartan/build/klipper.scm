(define-module (spartan build klipper)
  #:use-module (guix build utils)
  #:use-module (ice-9 rdelim)
  #:use-module (spartan build config-files)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-8)
  #:export (%klipper-config-reserved initialize-klipper-state))

(define %config-manifest ".guix-klipper-config-files")
(define %klipper-config-reserved (list "klippy.log" %config-manifest))

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

(define (replace-regular-file path mode write-content)
  (unless (memq (path-type path) '(#f regular))
    (error "Klipper configuration destination is not a regular file" path))
  (let* ((port (mkstemp! (string-append (dirname path) "/.klipper-seed-XXXXXX") "wb"))
         (temporary (port-filename port)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (write-content port)
        (chmod port mode)
        (close-port port)
        (rename-file temporary path))
      (lambda ()
        (unless (port-closed? port) (close-port port))
        (when (file-exists? temporary) (delete-file temporary))))))

(define (install-klipper-config state seed)
  (let loop ((directory state) (parts (string-split (car seed) #\/)))
    (let ((path (string-append directory "/" (car parts))))
      (if (null? (cdr parts))
          (replace-regular-file path #o640
            (lambda (port)
              (call-with-input-file (cdr seed)
                (lambda (input) (dump-port input port)) #:binary #t)))
          (begin
            (case (path-type path)
              ((directory) #t)
              ((#f) (mkdir path #o750))
              (else (error "Klipper configuration parent is not a directory" path)))
            (loop path (cdr parts)))))))

(define (read-config-manifest manifest)
  (case (path-type manifest)
    ((#f) '())
    ((regular)
     (call-with-input-file manifest
       (lambda (port)
         (let loop ((paths '()))
           (let ((path (read-line port)))
             (cond
              ((eof-object? path) (reverse paths))
              ((and (relative-file-name? path)
                    (not (any (lambda (other) (paths-overlap? path other))
                              %klipper-config-reserved)))
               (loop (cons path paths)))
              (else (error "Invalid Klipper configuration manifest entry" path))))))
       #:encoding "UTF-8"))
    (else (error "Klipper configuration manifest is not a regular file" manifest))))

(define (remove-retired-config state relative)
  (define (remove-empty-directory directory)
    (catch 'system-error
      (lambda () (rmdir directory))
      (lambda args
        (unless (memv (system-error-errno args) (list ENOENT ENOTEMPTY EEXIST))
          (apply throw args)))))
  (let loop ((directory state) (parts (string-split relative #\/)))
    (let ((path (string-append directory "/" (car parts))))
      (if (null? (cdr parts))
          (when (memq (path-type path) '(regular symlink))
            (delete-file path))
          (when (eq? (path-type path) 'directory)
            (loop path (cdr parts))
            ;; Retire empty parents without removing unrelated files.
            (remove-empty-directory path))))))

(define (install-klipper-configs state seeds)
  (let* ((manifest (string-append state "/" %config-manifest))
         (paths (map car seeds))
         (retired (lset-difference string=? (read-config-manifest manifest) paths)))
    (receive (blocking remaining)
        (partition (lambda (old)
                     (any (lambda (new) (paths-overlap? old new)) paths))
                   retired)
      ;; A retired file can block a new directory, or vice versa.
      (for-each (lambda (old) (remove-retired-config state old)) blocking)
      (for-each (lambda (seed) (install-klipper-config state seed)) seeds)
      (for-each (lambda (old) (remove-retired-config state old)) remaining))
    (replace-regular-file manifest #o600
      (lambda (port)
        (set-port-encoding! port "UTF-8")
        (for-each (lambda (path) (display path port) (newline port)) paths)))))

(define (call-as-klipper uid gid thunk)
  ;; Configuration directories are writable by Klipper and Moonraker. Never
  ;; traverse them as root when updating files, even if a path changes after lstat.
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
    (lambda () (install-klipper-configs state seeds)))
  (when firmware-source
    (initialize-klipper-firmware firmware-source
                                 (string-append run "/firmware") uid gid)))
