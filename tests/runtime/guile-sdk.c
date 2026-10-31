/* Exercise the same guile-snarf -> native C extension pipeline as Guile-Avahi. */
#include <libguile.h>

SCM_DEFINE (scm_mixed_probe, "mixed-probe", 0, 0, 0, (),
            "Return a value from a natively compiled Guile extension.")
{
  return scm_from_utf8_string ("mixed compilation");
}

void
scm_init_mixed_probe (void)
{
#ifndef SCM_MAGIC_SNARFER
#include "probe.x"
#endif
}
