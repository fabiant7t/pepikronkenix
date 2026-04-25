SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

NIX ?= nix
PROFILE ?= all
CONFIRM ?=
USB ?=
ISO ?=

ifeq ($(PROFILE),all)
NIXOS_CONFIG := pepikronkenix-all
else ifeq ($(PROFILE),cpu)
NIXOS_CONFIG := pepikronkenix-cpu
else ifeq ($(PROFILE),vulkan)
NIXOS_CONFIG := pepikronkenix-vulkan
else ifeq ($(PROFILE),cuda)
NIXOS_CONFIG := pepikronkenix-cuda
else ifeq ($(PROFILE),rocm)
NIXOS_CONFIG := pepikronkenix-rocm
else
$(error Unsupported PROFILE='$(PROFILE)'. Use all, cpu, vulkan, cuda, or rocm)
endif

ISO_ATTR := .\#nixosConfigurations.$(NIXOS_CONFIG).config.system.build.isoImage
ISO_NAME_ATTR := .\#nixosConfigurations.$(NIXOS_CONFIG).config.image.fileName
NIX_FLAGS ?= --extra-experimental-features 'nix-command flakes'

.PHONY: help kronk iso build build-all build-cpu build-vulkan build-cuda build-rocm check show-iso clean write-usb

help:
	@echo "pepikronkenix"
	@echo
	@echo "Build targets:"
	@echo "  make iso                  Build the all-in-one live ISO (CPU default boot)"
	@echo "  make iso PROFILE=vulkan   Build the Vulkan-only live ISO"
	@echo "  make build-all            Build all-in-one ISO with CPU/Vulkan/CUDA/ROCm boot entries"
	@echo "  make build-cpu            Build CPU-only ISO"
	@echo "  make build-vulkan         Build Vulkan ISO"
	@echo "  make build-cuda           Build CUDA ISO"
	@echo "  make build-rocm           Build ROCm ISO"
	@echo "  make kronk                Build only the Kronk package"
	@echo "  make check                Evaluate flake outputs"
	@echo
	@echo "USB target:"
	@echo "  sudo make write-usb USB=/dev/sdX CONFIRM=pepikronkenix"
	@echo "  sudo make write-usb ISO=result/iso/pepikronkenix-...iso USB=/dev/sdX CONFIRM=pepikronkenix"
	@echo
	@echo "Variables:"
	@echo "  PROFILE=$(PROFILE) (all|cpu|vulkan|cuda|rocm)"
	@echo "  USB=$(USB)"
	@echo "  ISO=$(ISO)"

kronk:
	$(NIX) build $(NIX_FLAGS) .#kronk

iso build:
	$(NIX) build $(NIX_FLAGS) $(ISO_ATTR)
	@$(MAKE) --no-print-directory show-iso

build-all:
	@$(MAKE) --no-print-directory iso PROFILE=all

build-cpu:
	@$(MAKE) --no-print-directory iso PROFILE=cpu

build-vulkan:
	@$(MAKE) --no-print-directory iso PROFILE=vulkan

build-cuda:
	@$(MAKE) --no-print-directory iso PROFILE=cuda

build-rocm:
	@$(MAKE) --no-print-directory iso PROFILE=rocm

check:
	$(NIX) flake show $(NIX_FLAGS)
	$(NIX) eval $(NIX_FLAGS) --raw $(ISO_NAME_ATTR)
	@echo

show-iso:
	@if [ -d result/iso ]; then \
		find -L result/iso -maxdepth 1 -type f -name '*.iso' -printf '%p\n'; \
	else \
		echo "No result/iso directory yet. Run make iso first."; \
	fi

write-usb:
	@if [ -z "$(USB)" ]; then echo "ERROR: set USB=/dev/sdX" >&2; exit 2; fi
	@if [ -z "$(ISO)" ]; then \
		iso=$$(find -L result/iso -maxdepth 1 -type f -name '*.iso' | sort | tail -n1); \
	else \
		iso="$(ISO)"; \
	fi; \
	if [ -z "$$iso" ]; then echo "ERROR: no ISO found. Run make iso or set ISO=/path/file.iso" >&2; exit 2; fi; \
	scripts/write-usb.sh "$$iso" "$(USB)" "$(CONFIRM)"

clean:
	rm -f result
	rm -rf result-*
