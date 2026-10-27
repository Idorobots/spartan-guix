(define-module (spartan build file-systems)
  #:use-module (gnu build file-systems)
  #:use-module (gnu system file-systems)
  #:use-module (guix build utils)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-34)
  #:export (resize-file-system))

(define* (resize-file-system file-system growpart resize-command
                             #:key (sysfs-directory "/sys/class/block"))
  "Grow FILE-SYSTEM's partition with GROWPART, then invoke RESIZE-COMMAND.
RESIZE-COMMAND maps the resolved device name to a command argument list.
SYSFS-DIRECTORY supplies Linux's block-device topology."
  (let* ((device (canonicalize-path
                  (canonicalize-device-spec (file-system-device file-system))))
         (partition (canonicalize-path
                     (string-append sysfs-directory "/" (basename device))))
         (number (call-with-input-file (string-append partition "/partition")
                   read-line))
         (parent (string-append "/dev/" (basename (dirname partition)))))
    ;; growpart returns 1 for NOCHANGE, and 2 for a failure. Even on NOCHANGE,
    ;; resize the filesystem: a previous boot may have grown the partition but
    ;; failed before growing the filesystem itself.
    (guard (condition ((and (invoke-error? condition)
                            (equal? (invoke-error-exit-status condition) 1))
                       (format #t "Partition ~a already fills its available space.~%"
                               device)))
      (invoke growpart parent number))
    (apply invoke (resize-command device))
    #t))
