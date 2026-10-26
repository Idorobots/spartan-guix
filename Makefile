GUIX ?= guix
GUIX_LOAD_FLAGS ?=
TARGET ?= aarch64-linux-gnu
TESTS := $(sort $(wildcard tests/*.scm))

.PHONY: check check-image check-discovery

# GUIX_LOAD_FLAGS permits a pinned Nonguix checkout when developing without an
# installed channel profile, e.g. make check GUIX_LOAD_FLAGS='-L ../nonguix'.
check:
	@set -eu; for test in $(TESTS); do \
		$(GUIX) repl -L . $(GUIX_LOAD_FLAGS) "$$test"; \
	done

# Lower the cross-compilation graph without building the kernel or SD image.
check-image:
	$(GUIX) system image -L . $(GUIX_LOAD_FLAGS) --target=$(TARGET) \
		--derivation gnu/system/images/raspberrypi.scm

# Exercise named discovery from an installed channel profile (as CI does).
check-discovery:
	$(GUIX) system image -L . $(GUIX_LOAD_FLAGS) --target=$(TARGET) \
		--image-type=rpi-raw --derivation \
		-e '(@ (gnu system images raspberrypi) rpi3-barebones-os)'
