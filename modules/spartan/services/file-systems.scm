(define-module (spartan services file-systems)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages file-systems)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system file-systems)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:export (resize-file-system-service-type
            resize-file-system-configuration
            resize-file-system-configuration?
            resize-file-system-configuration-file-system
            resize-file-system-configuration-cloud-utils
            resize-file-system-configuration-e2fsprogs
            resize-file-system-configuration-btrfs-progs
            resize-file-system-configuration-bcachefs-tools))

(define-record-type* <resize-file-system-configuration>
  resize-file-system-configuration make-resize-file-system-configuration
  resize-file-system-configuration?
  (file-system    resize-file-system-configuration-file-system)
  (cloud-utils    resize-file-system-configuration-cloud-utils
                  (default cloud-utils))
  (e2fsprogs      resize-file-system-configuration-e2fsprogs
                  (default e2fsprogs))
  (btrfs-progs    resize-file-system-configuration-btrfs-progs
                  (default btrfs-progs))
  (bcachefs-tools resize-file-system-configuration-bcachefs-tools
                  (default bcachefs-tools)))

(define (file-system-resize-command config)
  ;; Select before constructing the start gexp. Runtime dispatch would retain
  ;; every filesystem tool in the image's build graph, even for an ext4 root.
  (let ((fs (resize-file-system-configuration-file-system config)))
    (match (file-system-type fs)
      ((or "ext2" "ext3" "ext4")
       #~(lambda (device)
           (list #$(file-append
                    (resize-file-system-configuration-e2fsprogs config)
                    "/sbin/resize2fs")
                 device)))
      ("btrfs"
       #~(lambda (device)
           (list #$(file-append
                    (resize-file-system-configuration-btrfs-progs config)
                    "/bin/btrfs")
                 "filesystem" "resize" "max" #$(file-system-mount-point fs))))
      ("bcachefs"
       #~(lambda (device)
           (list #$(file-append
                    (resize-file-system-configuration-bcachefs-tools config)
                    "/sbin/bcachefs")
                 "device" "resize" device)))
      (type (error "Unsupported filesystem type for resizing" type)))))

(define (resize-file-system-shepherd-service config)
  (let* ((fs (resize-file-system-configuration-file-system config))
         (spec (file-system->spec fs))
         (resize-command (file-system-resize-command config)))
    (shepherd-service
     (documentation "Grow a partition and its filesystem to fill available space.")
     ;; Distinct mount points allow several instances in the same host.
     (provision (list (string->symbol
                      (string-append "resize-file-system-"
                                     (file-system-mount-point fs)))))
     (requirement
      (if (or (string=? "/" (file-system-mount-point fs))
              (file-system-needed-for-boot? fs))
          '(user-processes)
          ;; Filesystems with additional Shepherd requirements may be mounted
          ;; after the general file-systems target. Wait for this mount itself.
          (list 'user-processes
                (string->symbol
                 (string-append "file-system-" (file-system-mount-point fs))))))
     (one-shot? #t)
     (respawn? #f)
     (modules '((spartan build file-systems) (gnu system file-systems)))
     (start
      (with-imported-modules (source-module-closure
                              '((spartan build file-systems)
                                (gnu system file-systems)))
        #~(lambda _
            (resize-file-system
             (spec->file-system '#$spec)
             #$(file-append (resize-file-system-configuration-cloud-utils config)
                            "/bin/growpart")
             #$resize-command)))))))

(define resize-file-system-service-type
  (service-type
   (name 'resize-file-system)
   (description
    "Grow a partition and its ext2/3/4, Btrfs or bcachefs filesystem at boot,
including only the selected filesystem's tools in the build graph.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             (compose list resize-file-system-shepherd-service))))))
