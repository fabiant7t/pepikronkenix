SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

NIX ?= nix
PROFILE ?= all
CONFIRM ?=
USB ?=
IMAGE ?=

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

IMAGE_ATTR := .\#nixosConfigurations.$(NIXOS_CONFIG).config.system.build.image
IMAGE_NAME_ATTR := .\#nixosConfigurations.$(NIXOS_CONFIG).config.image.fileName
NIX_FLAGS ?= --extra-experimental-features 'nix-command flakes'

.PHONY: help kronk image build build-all build-cpu build-vulkan build-cuda build-rocm check show-image clean write-usb

help:
	@echo "pepikronkenix"
	@echo
	@echo "Build targets:"
	@echo "  make image                Build the all-in-one live USB disk image (CPU fallback boot entry)"
	@echo "  make image PROFILE=vulkan Build the Vulkan-only live USB disk image"
	@echo "  make build-all            Build all-in-one disk image with CPU/Vulkan/CUDA/ROCm boot entries"
	@echo "  make build-cpu            Build CPU-only disk image"
	@echo "  make build-vulkan         Build Vulkan disk image"
	@echo "  make build-cuda           Build CUDA disk image"
	@echo "  make build-rocm           Build ROCm disk image"
	@echo "  make kronk                Build only the Kronk package"
	@echo "  make check                Evaluate flake outputs"
	@echo
	@echo "USB target:"
	@echo "  sudo make write-usb USB=/dev/sdX CONFIRM=pepikronkenix"
	@echo "  sudo make write-usb IMAGE=result/pepikronkenix-...img USB=/dev/sdX CONFIRM=pepikronkenix"
	@echo
	@echo "Variables:"
	@echo "  PROFILE=$(PROFILE) (all|cpu|vulkan|cuda|rocm)"
	@echo "  USB=$(USB)"
	@echo "  IMAGE=$(IMAGE)"

kronk:
	$(NIX) build $(NIX_FLAGS) .#kronk

image build:
	$(NIX) build $(NIX_FLAGS) $(IMAGE_ATTR)
	@$(MAKE) --no-print-directory show-image

build-all:
	@$(MAKE) --no-print-directory image PROFILE=all

build-cpu:
	@$(MAKE) --no-print-directory image PROFILE=cpu

build-vulkan:
	@$(MAKE) --no-print-directory image PROFILE=vulkan

build-cuda:
	@$(MAKE) --no-print-directory image PROFILE=cuda

build-rocm:
	@$(MAKE) --no-print-directory image PROFILE=rocm

check:
	$(NIX) flake show $(NIX_FLAGS)
	$(NIX) eval $(NIX_FLAGS) --raw $(IMAGE_NAME_ATTR)
	@echo

show-image:
	@if [ -e result ]; then \
		find -L result -maxdepth 1 -type f \( -name '*.img' -o -name '*.raw' -o -name '*.qcow2' \) -printf '%p\n'; \
	else \
		echo "No result symlink yet. Run make image first."; \
	fi

write-usb:
	@if [ -z "$(USB)" ]; then echo "ERROR: set USB=/dev/sdX" >&2; exit 2; fi
	@if [ -z "$(IMAGE)" ]; then \
		image=$$(find -L result -maxdepth 1 -type f \( -name '*.img' -o -name '*.raw' \) | sort | tail -n1); \
	else \
		image="$(IMAGE)"; \
	fi; \
	if [ -z "$$image" ]; then echo "ERROR: no disk image found. Run make image or set IMAGE=/path/file.img" >&2; exit 2; fi; \
	scripts/write-usb.sh "$$image" "$(USB)" "$(CONFIRM)"

clean:
	rm -f result
	rm -rf result-*
