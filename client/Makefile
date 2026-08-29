FLUTTER_DIR := flutter
MANAGED_ENV := .env.managed

-include $(MANAGED_ENV)
export MANAGED_CP_URL MANAGED_CP_CONFIG_PUBLIC_KEY MANAGED_BOOTSTRAP_TOKEN

.DEFAULT_GOAL := help
.PHONY: help setup check managed-check managed-build-macos managed-build-windows managed-run-macos \
	flutter-get flutter-analyze flutter-test flutter-check flutter-build-macos flutter-build-windows \
	flutter-run-macos flutter-clean

help:
	@echo "Available targets:"
	@echo "  make setup                Fetch Flutter dependencies"
	@echo "  make check                Check Rust and Flutter client code"
	@echo "  make flutter-get          Fetch Flutter dependencies"
	@echo "  make flutter-analyze      Analyze the Flutter application"
	@echo "  make flutter-test         Run Flutter tests"
	@echo "  make flutter-build-macos  Build the debug macOS application"
	@echo "  make flutter-run-macos    Run the macOS application"
	@echo "  make flutter-clean        Remove generated Flutter build output"
	@echo "  make managed-check        Check a managed-only client using .env.managed"
	@echo "  make managed-build-macos  Build a managed-only macOS release"
	@echo "  make managed-build-windows Build a managed-only Windows release (run on Windows)"
	@echo "  make managed-run-macos    Run a managed-only macOS debug build"
	@echo "  make flutter-build-windows Build a standard Windows release (run on Windows)"

setup: flutter-get

check: flutter-check
	cargo check --lib --features flutter

managed-check:
	@if [ ! -f $(MANAGED_ENV) ] && { [ -z "$(MANAGED_CP_URL)" ] || [ -z "$(MANAGED_CP_CONFIG_PUBLIC_KEY)" ] || [ -z "$(MANAGED_BOOTSTRAP_TOKEN)" ]; }; then \
		echo "Copy .env.managed.example to $(MANAGED_ENV), or provide MANAGED_CP_URL, MANAGED_CP_CONFIG_PUBLIC_KEY, and MANAGED_BOOTSTRAP_TOKEN as environment variables."; \
		exit 1; \
	fi
	@test -n "$(MANAGED_CP_URL)" || (echo "MANAGED_CP_URL must be set."; exit 1)
	@test -n "$(MANAGED_CP_CONFIG_PUBLIC_KEY)" || (echo "MANAGED_CP_CONFIG_PUBLIC_KEY must be set."; exit 1)
	@test -n "$(MANAGED_BOOTSTRAP_TOKEN)" || (echo "MANAGED_BOOTSTRAP_TOKEN must be set."; exit 1)
	cargo check --lib --features flutter,managed-only

managed-build-macos: managed-check
	cargo build --release --lib --features flutter,managed-only
	cd $(FLUTTER_DIR) && flutter build macos --release --no-pub

managed-build-windows: managed-check
	cargo build --release --lib --features flutter,managed-only
	cd $(FLUTTER_DIR) && flutter build windows --release --no-pub

managed-run-macos: managed-check
	cargo build --lib --features flutter,managed-only
	cd $(FLUTTER_DIR) && flutter run -d macos --no-pub

flutter-get:
	cd $(FLUTTER_DIR) && flutter pub get

flutter-analyze:
	cd $(FLUTTER_DIR) && flutter analyze --no-pub

flutter-test:
	cd $(FLUTTER_DIR) && flutter test --no-pub

flutter-check: flutter-analyze flutter-test

flutter-build-macos:
	cd $(FLUTTER_DIR) && flutter build macos --debug --no-pub

flutter-build-windows:
	cd $(FLUTTER_DIR) && flutter build windows --release --no-pub

flutter-run-macos:
	cd $(FLUTTER_DIR) && flutter run -d macos

flutter-clean:
	cd $(FLUTTER_DIR) && flutter clean
