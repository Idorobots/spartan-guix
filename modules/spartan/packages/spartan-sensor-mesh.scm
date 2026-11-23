;; SPDX-License-Identifier: MIT
(define-module (spartan packages spartan-sensor-mesh)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages java)
  #:use-module (guix build-system copy)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages openjdk)
  #:export (spartan-sensor-mesh spartan-sensor-mesh-ui))

(define %spartan-sensor-mesh-license
  (origin
    (method url-fetch)
    (uri "https://raw.githubusercontent.com/Idorobots/spartan-sensor-mesh/v0.1.1/LICENSE")
    (file-name "spartan-sensor-mesh-LICENSE")
    (sha256
     (base32 "14qah8hzb7hvs570zj7wz0gkqpngpivalzqs5g146di6vk0byg8b"))))

(define-public spartan-sensor-mesh-ui
  (package
    (name "spartan-sensor-mesh-ui")
    (version "0.1.1")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/Idorobots/spartan-sensor-mesh/"
                           "releases/download/v" version "/"
                           "spartan-sensor-mesh-ui-v" version ".tar.gz"))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
        (base32 "11c3gh0drdps7fxl65ckli9vzg5k71mj1vrlarinmn7d6pvgygxm"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan #~'(("./" "share/spartan-sensor-mesh/ui"))
      #:phases
      #~(modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              (invoke "tar" "--no-same-owner" "-xvf" source)))
          (add-after 'install 'install-license
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((doc (string-append #$output "/share/doc/"
                                        #$name "-" #$version)))
                (mkdir-p doc)
                (copy-file (assoc-ref inputs "license")
                           (string-append doc "/LICENSE"))))))))
    (native-inputs
     `(("license" ,%spartan-sensor-mesh-license)))
    (home-page "https://github.com/Idorobots/spartan-sensor-mesh")
    (synopsis "Web interface for Spartan Sensor Mesh")
    (description
     "Pre-built web interface for the Spartan Sensor Mesh agent.  It is served
by the agent's REST endpoint and is also installed by the
@code{spartan-sensor-mesh} package.")
    (license license:expat)))

(define-public spartan-sensor-mesh
  (package
    (name "spartan-sensor-mesh")
    (version "0.1.1")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/Idorobots/spartan-sensor-mesh/"
                           "releases/download/v" version "/"
                           "spartan-sensor-mesh_3-" version ".jar"))
       (file-name (string-append "spartan-sensor-mesh_3-" version ".jar"))
       (sha256
        (base32 "1qb1ks4fklk5y5y1cjjxx0c3dlqi7q8qa7gcjm8r6896m9p0d99l"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~(list (list (string-append "spartan-sensor-mesh_3-" #$version ".jar")
                    "share/spartan-sensor-mesh/spartan-sensor-mesh.jar"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'install-ui
            (lambda* (#:key inputs #:allow-other-keys)
              (copy-recursively
               (string-append (assoc-ref inputs "spartan-sensor-mesh-ui")
                              "/share/spartan-sensor-mesh/ui")
               (string-append #$output "/share/spartan-sensor-mesh/data"))))
          (add-after 'install-ui 'install-wrapper
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((bin (string-append #$output "/bin"))
                     (java (assoc-ref inputs "openjdk"))
                     (bash (assoc-ref inputs "bash-minimal"))
                     (jar (string-append #$output
                                         "/share/spartan-sensor-mesh/"
                                         "spartan-sensor-mesh.jar")))
                (mkdir-p bin)
                (call-with-output-file (string-append bin "/spartan-sensor-mesh")
                  (lambda (port)
                    (format port "#!~a/bin/bash~%export JAVA_HOME=~a~%exec ~a/bin/java -jar ~a \"$@\"~%"
                            bash java java jar)))
                (chmod (string-append bin "/spartan-sensor-mesh") #o555))))
          (add-after 'install-wrapper 'install-license
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((doc (string-append #$output "/share/doc/"
                                        #$name "-" #$version)))
                (mkdir-p doc)
                (copy-file (assoc-ref inputs "license")
                           (string-append doc "/LICENSE"))))))))
    (inputs
     (list bash-minimal
           (if (string=? "armhf-linux"
                         (gnu-triplet->nix-system
                          (or (%current-target-system) (%current-system))))
               openjdk-armhf
               openjdk)
           spartan-sensor-mesh-ui))
    (native-inputs
     `(("license" ,%spartan-sensor-mesh-license)))
    (home-page "https://github.com/Idorobots/spartan-sensor-mesh")
    (synopsis "JVM agent for the Spartan Sensor Mesh")
    (description
     "Agent and web interface for the Spartan Sensor Mesh.  The agent samples
configured sensors, exposes mesh and data REST APIs, and serves the bundled
web interface.  The package runs the released JVM uberjar and includes the
matching pre-built UI assets.")
    (license license:expat)))
