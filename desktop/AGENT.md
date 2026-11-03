# RustDesk Development Guide

## Project Structure

- `src/` contains the Rust application, protocol, platform services, and IPC.
- `libs/` contains shared Rust crates for configuration, capture, input,
  clipboard, printing, and platform support.
- `flutter/` is the active Aurora Flutter UI.
- `flutter/lib/app/` owns app bootstrap and theming.
- `flutter/lib/features/workspace/` owns dashboard, peers, and settings.
- `flutter/lib/features/session/` owns remote-session surfaces and controls.
- `flutter_legacy/` is a read-only behavioral reference during migration.
- `res/` and platform runner directories contain installer/runtime resources.

## Flutter Architecture

1. Keep visual widgets separate from RustDesk integration adapters. Widgets
   receive view state and callbacks; adapters own FFI, option keys, and models.
2. Preserve every public bridge API, Rust option key, peer/address-book/group
   structure, and multi-window event contract from `flutter_legacy/`.
3. Never use sample data after an adapter exists. Represent loading, empty,
   offline, denied, and error states explicitly.
4. Keep feature code in its feature directory. Extract shared UI primitives
   only after two independent features need the same behavior.
5. Use routes for full-page mobile/detail flows and the existing window/tab
   coordinator for desktop session tools.

## UI Rules

- Use `Cupertino` and custom Aurora components; do not introduce Material UI in
  the active Aurora surface.
- Use `lucide_icons_flutter` for all new UI icons. Keep existing specialized
  native/custom icons only where compatibility requires them.
- Preserve the compact desktop density, terracotta/ivory Aurora palette, warm
  dark mode, and subtle transparent gradients.
- Hover changes background only. Do not scale menu items or use Material
  ripples. Dropdown menus anchor to their control and keep options compact.
- Keep keyboard focus, screen-reader semantics, long strings, RTL, and narrow
  mobile layouts working for every interactive component.

## Coding Style

- Use Dart formatter output and `flutter analyze`; do not silence warnings.
- Prefer small private widgets and typed callbacks over unstructured maps.
- Dispose controllers, focus nodes, streams, overlays, and FFI subscriptions.
- Avoid mutable global UI state. Keep transient state in its feature and expose
  persistent/native state through an adapter.
- Do not rename translation keys, option keys, FFI methods, or serialized peer
  fields as part of UI work.
- Use ASCII unless the file already requires localized Unicode content.

## Rust and Native Boundaries

- Do not alter protocol, connection, reconnect, file-transfer, or session
  behavior while redesigning UI.
- Propagate errors to the UI; do not replace failures with fake success states.
- Do not hold locks across `.await`, add nested Tokio runtimes, or use
  `unwrap()`/`expect()` in production Rust code.
- Keep platform code platform-specific and avoid broad refactors for a UI hook.

## Verification

- Run `flutter analyze --no-pub` and `flutter test --no-pub` after Flutter
  changes.
- Build the affected platform before handoff; for macOS use
  `flutter build macos --debug --no-pub`.
- Add regression coverage whenever a session action, settings option, dropdown,
  route, or native callback is introduced or changed.
- Before committing, inspect the diff and confirm only intended surfaces and
  execution flows changed.

## Cleanup Policy

- Keep native installer/runtime configuration needed to build locally.
- Do not add public release, store-upload, CI, Flatpak, AppImage, or Fastlane
  automation unless explicitly requested.
- Treat `flutter_legacy/` as backup/reference material; do not delete or alter
  it until functional parity is accepted.
