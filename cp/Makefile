CP_IMAGE ?= cr.0xh4ck3d.dev/c/rustdesk-cp
CP_UI_IMAGE ?= cr.0xh4ck3d.dev/c/rustdesk-cp-ui
IMAGE_TAG ?= latest
YARN ?= corepack yarn

.DEFAULT_GOAL := help
.PHONY: help install ui-install api-build ui-build build test managed-keys \
	api-image ui-image images api-push ui-push push

help:
	@echo "Available targets:"
	@echo "  make install      Install the portal's Yarn dependencies"
	@echo "  make api-build    Build the control-plane API release binary"
	@echo "  make ui-build     Build the React portal"
	@echo "  make build        Build the API and portal in parallel"
	@echo "  make test         Run control-plane Rust tests"
	@echo "  make managed-keys Generate CP signing keys and client public key"
	@echo "  make images       Build API and portal Docker images in parallel"
	@echo "  make push         Build and push both images"
	@echo "  Set CP_IMAGE, CP_UI_IMAGE, and IMAGE_TAG for your registry/tag."

install: ui-install

ui-install:
	cd ui && $(YARN) install --immutable

api-build:
	cargo build --release -p control-plane-api

ui-build:
	cd ui && $(YARN) build

build:
	$(MAKE) -j2 api-build ui-build

test:
	cargo test --workspace

managed-keys:
	./scripts/generate-managed-keys.sh

api-image:
	docker build --platform linux/amd64 -t $(CP_IMAGE):$(IMAGE_TAG) .

ui-image:
	docker build --platform linux/amd64 -t $(CP_UI_IMAGE):$(IMAGE_TAG) -f ui/Dockerfile ui

images:
	$(MAKE) -j2 api-image ui-image

api-push: api-image
	docker push $(CP_IMAGE):$(IMAGE_TAG)

ui-push: ui-image
	docker push $(CP_UI_IMAGE):$(IMAGE_TAG)

push:
	$(MAKE) -j2 api-push ui-push
