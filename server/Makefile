SERVER_IMAGE ?= cr.0xh4ck3d.dev/c/rustdesk-server
IMAGE_TAG ?= latest
# server-image targets linux/amd64, so the s6 overlay must use that architecture.
S6_ARCH ?= x86_64

.DEFAULT_GOAL := help
.PHONY: help check build image push

help:
	@echo "Available targets:"
	@echo "  make check  Check the server Rust workspace"
	@echo "  make build  Build hbbs and hbbr release binaries"
	@echo "  make image  Build one Linux image containing hbbs and hbbr"
	@echo "  make push   Build and push SERVER_IMAGE:IMAGE_TAG"

check:
	cargo check

build:
	cargo build --release --bin hbbs --bin hbbr

image:
	docker build --build-arg S6_ARCH=$(S6_ARCH) --platform linux/amd64 -f docker/Dockerfile -t $(SERVER_IMAGE):$(IMAGE_TAG) ..

push: image
	docker push $(SERVER_IMAGE):$(IMAGE_TAG)
