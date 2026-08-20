FLUTTER_DIR := client/flutter

.DEFAULT_GOAL := help
.PHONY: help setup flutter-get flutter-analyze flutter-test flutter-check \
	flutter-build-macos flutter-run-macos flutter-clean client-check server-check \
	cp-test cp-ui-install cp-ui-build check

help:
	@echo "Available targets:"
	@echo "  make setup                Install Flutter and control-panel UI dependencies"
	@echo "  make flutter-get          Fetch Flutter dependencies"
	@echo "  make flutter-analyze      Analyze the Flutter application"
	@echo "  make flutter-test         Run Flutter tests"
	@echo "  make flutter-check        Analyze and test Flutter"
	@echo "  make flutter-build-macos  Build the debug macOS application"
	@echo "  make flutter-run-macos    Run the Flutter app on macOS"
	@echo "  make flutter-clean        Remove generated Flutter build output"
	@echo "  make client-check         Check the RustDesk client Rust workspace"
	@echo "  make server-check         Check the server Rust workspace"
	@echo "  make cp-test              Test the control-plane Rust workspace"
	@echo "  make cp-ui-build          Build the control-panel UI"
	@echo "  make check                Run all non-destructive verification targets"

setup: flutter-get cp-ui-install

flutter-get:
	cd $(FLUTTER_DIR) && flutter pub get

flutter-analyze:
	cd $(FLUTTER_DIR) && flutter analyze --no-pub

flutter-test:
	cd $(FLUTTER_DIR) && flutter test --no-pub

flutter-check: flutter-analyze flutter-test

flutter-build-macos:
	cd $(FLUTTER_DIR) && flutter build macos --debug --no-pub

flutter-run-macos:
	cd $(FLUTTER_DIR) && flutter run -d macos

flutter-clean:
	cd $(FLUTTER_DIR) && flutter clean

client-check:
	cd client && cargo check --lib --features flutter

server-check:
	cd server && cargo check

cp-test:
	cd cp && cargo test --workspace

cp-ui-install:
	cd cp-ui && npm ci

cp-ui-build:
	cd cp-ui && npm run build

check: flutter-check client-check server-check cp-test cp-ui-build
