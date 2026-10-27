(use-modules (gnu packages admin)
             (gnu packages file-systems)
             (gnu packages linux)
             (gnu services)
             (gnu services shepherd)
             (gnu system file-systems)
             (guix build utils)
             (guix gexp)
             (guix packages)
             (guix utils)
             (ice-9 textual-ports)
             (spartan build file-systems)
             (spartan services file-systems)
             (srfi srfi-1)
             (srfi srfi-34)
             (srfi srfi-64))

(test-begin "file-systems")

(define* (configuration type #:optional (mount-point "/"))
  (resize-file-system-configuration
   (file-system (file-system
                 (device (file-system-label "data"))
                 (mount-point mount-point)
                 (type type)))))

(define (shepherd config)
  (car ((service-extension-compute
         (car (service-type-extensions resize-file-system-service-type)))
        config)))

;; Inspect the inputs of the actual start procedure, not the defaults stored
;; in its configuration. Unused defaults must not become build dependencies.
(define (tool-packages config)
  (sort
   (filter-map
    (lambda (input)
      (let ((thing (gexp-input-thing input)))
        (and (file-append? thing)
             (package? (file-append-base thing))
             (package-name (file-append-base thing)))))
    ((@@ (guix gexp) gexp-inputs) (shepherd-service-start (shepherd config))))
   string<?))

(for-each
 (lambda (type)
   (test-equal (string-append type " retains only growpart and resize2fs")
     '("cloud-utils" "e2fsprogs")
     (tool-packages (configuration type))))
 '("ext2" "ext3" "ext4"))

(test-equal "Btrfs retains only its selected tool"
  '("btrfs-progs" "cloud-utils")
  (tool-packages (configuration "btrfs" "/data")))

(test-equal "bcachefs retains only its selected tool"
  '("bcachefs-tools" "cloud-utils")
  (tool-packages (configuration "bcachefs" "/data")))

(test-equal "tool packages can be overridden"
  '("cloud-utils" "custom-e2fsprogs")
  (tool-packages
   (resize-file-system-configuration
    (inherit (configuration "ext4"))
    (e2fsprogs (package (inherit e2fsprogs) (name "custom-e2fsprogs"))))))

;; Approximation replaces each file-append with (*approximate*). Supply a
;; harmless executable name while evaluating the generated command procedure.
(define (*approximate*) "/mock/tool")
(define (command config device)
  ((eval (gexp->approximate-sexp
          ((@@ (spartan services file-systems) file-system-resize-command) config))
         (current-module))
   device))

(test-equal "ext4 resize targets the resolved partition"
  '("/mock/tool" "/dev/nvme0n1p2")
  (command (configuration "ext4") "/dev/nvme0n1p2"))

(test-equal "Btrfs grows to max using the mount point, not the device"
  '("/mock/tool" "filesystem" "resize" "max" "/data")
  (command (configuration "btrfs" "/data") "/dev/sda2"))

(test-equal "bcachefs resize targets the resolved partition"
  '("/mock/tool" "device" "resize" "/dev/sda2")
  (command (configuration "bcachefs" "/data") "/dev/sda2"))

(test-error "unsupported filesystems are rejected during service generation"
  #t
  (shepherd (configuration "vfat")))

(test-assert "different mount points have independent Shepherd provisions"
  (not (equal? (shepherd-service-provision (shepherd (configuration "ext4")))
               (shepherd-service-provision
                (shepherd (configuration "ext4" "/data"))))))

(test-assert "resize runs once after filesystems are available"
  (let ((service (shepherd (configuration "ext4"))))
    (and (shepherd-service-one-shot? service)
         (not (shepherd-service-respawn? service))
         (memq 'user-processes (shepherd-service-requirement service)))))

(test-assert "non-root resize waits for its own mount"
  (memq 'file-system-/data
        (shepherd-service-requirement
         (shepherd (configuration "btrfs" "/data")))))

(define (write-program file text)
  (call-with-output-file file
    (lambda (port) (display (string-append "#!/bin/sh\n" text) port)))
  (chmod file #o755))

;; Exercise the real runtime helper using a synthetic sysfs tree and harmless
;; commands. No block devices, root privileges, or mounts are required.
(define (run-resize grow-status resize-status)
  (let* ((directory (mkdtemp "/tmp/spartan-resize-test-XXXXXX"))
         (device (string-append directory "/mmcblk0p2"))
         (alias (string-append directory "/root-device"))
         (sysfs (string-append directory "/block"))
         (partition (string-append directory "/devices/mmcblk0/mmcblk0p2"))
         (log (string-append directory "/commands"))
         (growpart (string-append directory "/growpart"))
         (resize (string-append directory "/resize2fs")))
    (dynamic-wind
      (lambda ()
        (mkdir-p partition)
        (mkdir sysfs)
        (call-with-output-file device (const #t))
        (symlink device alias)
        (symlink partition (string-append sysfs "/mmcblk0p2"))
        (call-with-output-file (string-append partition "/partition")
          (lambda (port) (display "2\n" port)))
        (write-program growpart
          (format #f "printf 'grow %s\\n' \"$*\" >> '~a'\nexit ~a\n"
                  log grow-status))
        (write-program resize
          (format #f "printf 'resize %s\\n' \"$*\" >> '~a'\nexit ~a\n"
                  log resize-status)))
      (lambda ()
        (let ((result
               (guard (condition ((invoke-error? condition)
                                  (invoke-error-exit-status condition)))
                 (resize-file-system
                  (file-system (device alias) (mount-point "/") (type "ext4"))
                  growpart (lambda (device) (list resize device))
                  #:sysfs-directory sysfs))))
          (list result
                ;; Normalize the random temporary prefix for stable assertions.
                (string-replace-substring
                 (call-with-input-file log get-string-all) directory "FIXTURE"))))
      (lambda () (delete-file-recursively directory)))))

(test-equal "growpart precedes filesystem resizing and device aliases resolve"
  '(#t "grow /dev/mmcblk0 2\nresize FIXTURE/mmcblk0p2\n")
  (run-resize 0 0))

(test-equal "NOCHANGE still retries filesystem growth after an interrupted boot"
  '(#t "grow /dev/mmcblk0 2\nresize FIXTURE/mmcblk0p2\n")
  (run-resize 1 0))

(test-equal "partition growth failures prevent filesystem resizing"
  '(2 "grow /dev/mmcblk0 2\n")
  (run-resize 2 0))

(test-equal "filesystem resize failures propagate"
  '(3 "grow /dev/mmcblk0 2\nresize FIXTURE/mmcblk0p2\n")
  (run-resize 0 3))

(test-equal "filesystem exit 1 is not mistaken for growpart NOCHANGE"
  '(1 "grow /dev/mmcblk0 2\nresize FIXTURE/mmcblk0p2\n")
  (run-resize 0 1))

(define runner (test-runner-current))
(test-end "file-systems")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
