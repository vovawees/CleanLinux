# Clean Linux — top-level Makefile
# Targets:
#   make build            — build the default ISO profile
#   make build PROFILE=…  — build a specific profile
#   make clean            — remove work/ and out/
#   make shell            — chroot into the last build's work directory (debug)

PROFILE ?= profiles/cleanlinux

.PHONY: build clean shell help
.DEFAULT_GOAL := help

build:
	@bash scripts/build.sh "$(PROFILE)"

clean:
	@echo "==> Removing work/ and out/"
	@rm -rf work out

shell:
	@test -d work/x86_64/airootfs || { echo "No built airootfs. Run 'make build' first."; exit 1; }
	@sudo arch-chroot work/x86_64/airootfs

help:
	@echo "Clean Linux build system"
	@echo "  make build [PROFILE=path]  - build an ISO profile"
	@echo "  make clean                 - remove work/ and out/"
	@echo "  make shell                 - chroot into the built airootfs"
