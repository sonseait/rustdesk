.DEFAULT_GOAL := help
.PHONY: help check build

help:
	@echo "Available targets:"
	@echo "  make check  Check the server Rust workspace"
	@echo "  make build  Build hbbs and hbbr release binaries"

check:
	cargo check

build:
	cargo build --release --bin hbbs --bin hbbr
