#
# Description: Builds the per-process network eBPF object consumed by ebpf_exporter.
# Created by: Mustafa Can Caliskan
# Date: 2026-08-23
#

.DEFAULT_GOAL := build

CLANG ?= clang
BPFTOOL ?= bpftool
DOCKER ?= docker

ARCH := $(shell uname -m | sed -e 's/x86_64/x86/' -e 's/aarch64/arm64/')

BPF_SRC := bpf/process-network.bpf.c
BPF_OBJ := dist/process-network.bpf.o
CONFIG := config/process-network.yaml
VMLINUX := build/vmlinux.h

EXPORTER_VERSION ?= v2.5.1
EXPORTER_BASE_URL := https://github.com/cloudflare/ebpf_exporter/releases/download/$(EXPORTER_VERSION)
BUILDER_IMAGE ?= network-per-process-builder

# Architectures the offline bundle carries exporter binaries for.
BUNDLE_ARCHS ?= x86_64 aarch64
BUNDLE_DIR := bundle

# Clang does not know its own system include paths when cross-targeting bpf,
# so they are discovered and appended explicitly.
CLANG_BPF_SYS_INCLUDES := $(shell $(CLANG) -v -E - </dev/null 2>&1 \
	| sed -n '/<...> search starts here:/,/End of search list./{ s| \(/.*\)|-idirafter \1|p }')

CFLAGS := -g -O2 -Wall -Werror -mcpu=v3 -target bpf -D__TARGET_ARCH_$(ARCH)

.PHONY: build
build: $(BPF_OBJ) dist/$(notdir $(CONFIG))

$(VMLINUX):
	@mkdir -p $(dir $@)
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $@

$(BPF_OBJ): $(BPF_SRC) $(VMLINUX)
	@mkdir -p $(dir $@)
	$(CLANG) $(CFLAGS) -I$(dir $(VMLINUX)) $(CLANG_BPF_SYS_INCLUDES) -c $< -o $@

dist/$(notdir $(CONFIG)): $(CONFIG)
	@mkdir -p dist
	cp $< $@

# Reproducible build with no host toolchain: everything happens in the image.
.PHONY: build-docker
build-docker:
	$(DOCKER) build --file build/Dockerfile --tag $(BUILDER_IMAGE) .
	@mkdir -p dist
	$(DOCKER) run --rm -e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g) \
		-v $(CURDIR)/dist:/out $(BUILDER_IMAGE)

# Exporter image with the probe baked in, for the single-machine demo stack.
.PHONY: image
image:
	$(DOCKER) build --file deploy/local/Dockerfile.exporter --tag network-per-process-exporter:latest .

# Smoke test on this machine: loads the probe and serves metrics on :9435.
.PHONY: run-local
run-local: build
	$(DOCKER) run --rm -it --privileged -p 9435:9435 -v $(CURDIR)/dist:/config:ro \
		ghcr.io/cloudflare/ebpf_exporter:$(EXPORTER_VERSION) \
		--config.dir=/config --config.names=process-network

# Everything an air-gapped environment needs, in one archive: the compiled
# probe, exporter binaries for every supported architecture, and the deployment
# files. Run this where there is internet; carry bundle.tar.gz across.
.PHONY: bundle
bundle:
	@test -f dist/process-network.bpf.o || { echo "run 'make build' or 'make build-docker' first"; exit 1; }
	rm -rf $(BUNDLE_DIR) $(BUNDLE_DIR).tar.gz
	mkdir -p $(BUNDLE_DIR)/prometheus $(BUNDLE_DIR)/grafana
	cp dist/process-network.bpf.o dist/process-network.yaml $(BUNDLE_DIR)/
	cp deploy/central/install.sh $(BUNDLE_DIR)/
	cp deploy/nodes.txt $(BUNDLE_DIR)/
	cp deploy/systemd/node-install.sh deploy/systemd/ebpf-exporter.service $(BUNDLE_DIR)/
	cp deploy/prometheus/scrape-config.yaml $(BUNDLE_DIR)/prometheus/
	cp grafana/dashboard.json $(BUNDLE_DIR)/grafana/
	for arch in $(BUNDLE_ARCHS); do \
		curl -sfL --retry 3 -o $(BUNDLE_DIR)/ebpf_exporter.$$arch \
			$(EXPORTER_BASE_URL)/ebpf_exporter.$$arch || exit 1; \
		chmod 0755 $(BUNDLE_DIR)/ebpf_exporter.$$arch; \
	done
	cd $(BUNDLE_DIR) && find . -type f ! -name sha256sums.txt | sort | xargs sha256sum > sha256sums.txt
	tar -czf $(BUNDLE_DIR).tar.gz $(BUNDLE_DIR)
	@echo "bundle ready: $(BUNDLE_DIR).tar.gz"

.PHONY: clean
clean:
	rm -rf dist $(BUNDLE_DIR) $(BUNDLE_DIR).tar.gz $(VMLINUX)
