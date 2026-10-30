(define-module (spartan packages maths)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages maths)
  #:use-module (gnu packages rrdtool)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (spartan packages cross)
  #:use-module (spartan packages gtk)
  #:use-module (spartan packages rrdtool)
  #:export (gnuplot/cross-fixed
            package-with-cross-fixed-plotting))

(define gnuplot/cross-fixed
  (package
    (inherit gnuplot)
    (native-inputs
     (if (%current-target-system)
         (modify-inputs (package-native-inputs gnuplot)
           ;; Documentation generation executes Lua on the build machine;
           ;; keep the target Lua input for the plotting executable too.
           (prepend (lookup-package-input gnuplot "lua")))
         (package-native-inputs gnuplot)))
    (inputs
     (if (%current-target-system)
         (modify-inputs (package-inputs gnuplot)
           (replace "pango" pango/cross-fixed))
         (package-inputs gnuplot)))))

(define package-with-cross-fixed-plotting
  (package-input-rewriting/cross
   `((,gnuplot . ,gnuplot/cross-fixed)
     (,rrdtool . ,rrdtool/cross-fixed)
     (,pango . ,pango/cross-fixed))))
