GUIX ?= guix
GUIX_LOAD_FLAGS ?=
SYSTEM ?= aarch64-linux
IMAGE ?= rpi3-barebones-raw-image
TESTS := $(sort $(wildcard tests/*.scm))

.PHONY: check check-image check-discovery check-image-derivation
.PHONY: check-image-armhf check-image-a53 check-image-aarch64

# GUIX_LOAD_FLAGS permits a pinned Nonguix checkout when developing without an
# installed channel profile, e.g. make check GUIX_LOAD_FLAGS='-L ../nonguix'.
check:
	@set -eu; for test in $(TESTS); do \
		$(GUIX) repl -L modules $(GUIX_LOAD_FLAGS) "$$test"; \
	done

# Check the native graph's next build stage without realizing graft inputs.
check-image: check-image-armhf check-image-a53 check-image-aarch64

check-image-armhf:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=armhf-linux \
		--image-type=rpi2-raw --dry-run \
		-e '(@ (gnu system images raspberrypi) rpi2-barebones-os)'

check-image-a53:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=aarch64-linux \
		--image-type=rpi-raw --dry-run \
		-e '(@ (gnu system images raspberrypi) rpi3-barebones-os)'

check-image-aarch64:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=aarch64-linux \
		--image-type=rpi4-raw --dry-run \
		-e '(@ (gnu system images raspberrypi) rpi4-barebones-os)'

# Exercise named discovery from an installed channel profile (as CI does).
check-discovery:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=$(SYSTEM) \
		--image-type=rpi-raw --dry-run \
		-e '(@ (gnu system images raspberrypi) rpi3-barebones-os)'

# Integration check: graft analysis can build custom Guix/Shepherd prerequisites.
# Requires native/offloaded/emulated AArch64 execution for those cache misses.
check-image-derivation:
	$(GUIX) system image -L modules $(GUIX_LOAD_FLAGS) --system=$(SYSTEM) \
		--derivation -e '(@ (gnu system images raspberrypi) $(IMAGE))'
