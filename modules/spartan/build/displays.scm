(define-module (spartan build displays)
  #:use-module (guix build utils)
  #:use-module (guix build kconfig)
  #:use-module (ice-9 regex)
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module (rnrs bytevectors)
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:use-module (srfi srfi-1)
  #:export (write-seeedstudio-7inch-edid
            configure-seeedstudio-display-firmware))

(define (write-seeedstudio-7inch-edid file)
  "Write a synthetic EDID for Seeed's 7-inch 720x1280 HDMI panel to FILE."
  ;; The detailed timing is the vendor's 70 MHz, negative-sync mode:
  ;; H: 720 + 100 + 24 + 52; V: 1280 + 10 + 4 + 4 (60.18875 Hz).
  ;; This describes the panel, not its separate USB touch controller.
  (let* ((bytes
          (append
           '(#x00 #xff #xff #xff #xff #xff #xff #x00
             #x4e #x14                 ;synthetic SPT manufacturer ID
             #x01 #x00 #x00 #x00 #x00 #x00
             #x00 #x24 #x01 #x04        ;manufactured 2026; EDID 1.4
             #xa2 #x09 #x10 #x78 #x06   ;8-bit HDMI, 9x16 cm, gamma 2.2
             #xee #x91 #xa3 #x54 #x4c #x99 #x26 #x0f #x50 #x54 ;sRGB
             #x00 #x00 #x00)            ;no established timings
           (make-list 16 #x01)          ;no standard timings
           '(#x58 #x1b #xd0 #xb0 #x20 #x00 #x12 #x50
             #x64 #x18 #xa4 #x00 #x57 #x9b #x00 #x00 #x00 #x18)
           '(#x00 #x00 #x00 #xfc #x00)
           (map char->integer (string->list "Seeed 7 inch\n"))
           '(#x00 #x00 #x00 #xfd #x00 #x3c #x3d #x4e #x4f #x07
             #x01 #x0a #x20 #x20 #x20 #x20 #x20 #x20)
           '(#x00 #x00 #x00 #x10 #x00 #x00 #x00 #x00 #x00
             #x00 #x00 #x00 #x00 #x00 #x00 #x00 #x00 #x00)
           '(#x00)))                   ;no extension blocks
         (checksum (modulo (- (apply + bytes)) 256)))
    (unless (= 127 (length bytes))
      (error "incorrect EDID block length" (length bytes)))
    (call-with-output-file file
      (lambda (port)
        (put-bytevector port (u8-list->bytevector (append bytes (list checksum))))))))

(define (configure-seeedstudio-display-firmware firmware)
  "Embed FIRMWARE's EDID in a configured kernel, retaining other built-in blobs."
  ;; A built-in EDID is available before root or the firmware activation service.
  ;; Keep other EXTRA_FIRMWARE entries, even when their directory is read-only.
  (let* ((text (call-with-input-file ".config" get-string-all))
         (value (lambda (name default)
                  (let ((match (string-match
                                (string-append "(^|\n)" name "=(\"[^\"]*\")")
                                text)))
                    (if match
                        (call-with-input-string (match:substring match 2) read)
                        default))))
         (old-directory (value "CONFIG_EXTRA_FIRMWARE_DIR" "firmware"))
         (names (delete-duplicates
                 (append (string-tokenize (value "CONFIG_EXTRA_FIRMWARE" ""))
                         '("edid/seeedstudio-7inch-720x1280.bin"))))
         (directory "spartan-display-firmware")
         (settings
          (list (string-append "CONFIG_EXTRA_FIRMWARE=\""
                               (string-join names " ") "\"")
                (string-append "CONFIG_EXTRA_FIRMWARE_DIR=\"" directory "\""))))
    (for-each
     (lambda (name)
       (let ((target (string-append directory "/" name)))
         (mkdir-p (dirname target))
         (copy-file
          (string-append (if (string=? "edid/seeedstudio-7inch-720x1280.bin" name)
                             firmware old-directory)
                         "/" name)
          target)))
     names)
    (modify-defconfig ".config" settings)
    (invoke "make" "olddefconfig")
    (call-with-output-file "spartan-display.config"
      (lambda (port)
        (for-each (lambda (line) (display line port) (newline port)) settings)))
    (verify-config ".config" "spartan-display.config")))
