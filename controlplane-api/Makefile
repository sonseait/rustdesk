YARN ?= corepack yarn

.DEFAULT_GOAL := help
.PHONY: help install ui-install api-build ui-build build test managed-keys

help:
	@echo "Available targets:"
	@echo "  make install      Install the portal's Yarn dependencies"
	@echo "  make api-build    Build the control-plane API release binary"
	@echo "  make ui-build     Build the React portal"
	@echo "  make build        Build the API and portal in parallel"
	@echo "  make test         Run control-plane Rust tests"
	@echo "  make managed-keys Generate CP signing keys and client public key"

install: ui-install

ui-install:
	cd ../controlplane-ui && $(YARN) install --immutable

api-build:
	cargo build --release -p control-plane-api

ui-build:
	cd ../controlplane-ui && $(YARN) build

build:
	$(MAKE) -j2 api-build ui-build

test:
	cargo test --workspace

managed-keys:
	./scripts/generate-managed-keys.sh
