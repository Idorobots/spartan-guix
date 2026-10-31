GUIX ?= guix
GUIX_LOAD_FLAGS ?=
SYSTEM ?= aarch64-linux
TESTS := $(sort $(wildcard tests/*.scm))

.PHONY: check check-image check-discovery check-image-derivation

# GUIX_LOAD_FLAGS permits a pinned Nonguix checkout when developing without an
# installed channel profile, e.g. make check GUIX_LOAD_FLAGS='-L ../nonguix'.
check:
	@set -eu; for test in $(TESTS); do \
		$(GUIX) repl -L modules $(GUIX_LOAD_FLAGS) "$$test"; \
	done

# Check the native graph's next build stage without realizing graft inputs.
check-image:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=$(SYSTEM) \
		--dry-run modules/gnu/system/images/raspberrypi.scm

# Exercise named discovery from an installed channel profile (as CI does).
check-discovery:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=$(SYSTEM) \
		--image-type=rpi-raw --dry-run \
		-e '(@ (gnu system images raspberrypi) rpi3-barebones-os)'

# Integration check: graft analysis can build custom Guix/Shepherd prerequisites.
# Requires native/offloaded/emulated AArch64 execution for those cache misses.
check-image-derivation:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=$(SYSTEM) \
		--derivation modules/gnu/system/images/raspberrypi.scm
