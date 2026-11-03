# Flutter Reimplementation Plan

## Goal

Replace the legacy Flutter UI with the Aurora UI without changing the RustDesk
protocol, FFI API, option keys, peer data, native-window behavior, or
localization keys. `flutter_legacy/` is the behavioral reference until each
flow has been migrated and verified.

## Rules

- Do not copy the legacy Material UI. Extract its model and FFI behavior behind
  narrow adapters, then build Aurora screens from those adapters.
- Do not invent session, peer, service, or settings data. Every displayed value
  must come from an existing model or an explicitly marked temporary fixture.
- Preserve public FFI calls, option keys, `SettingsTabKey` deep links, address
  book/group structures, and multi-window event contracts.
- Ship each milestone only after its unit/widget tests and platform smoke tests
  pass.

## Milestone 0: Integration Foundation

1. Restore the Flutter-to-Rust bridge and application bootstrap needed by the
   active UI.
2. Add read-only adapters for `ServerModel`, peers, address books, groups,
   session state, user/account state, and plugin state.
3. Add an option repository that reads and writes the existing `bind` option
   keys; respect fixed/managed options and platform availability.
4. Add a route/window coordinator that accepts the existing connection and
   multi-window events before replacing visual surfaces.

Acceptance: the app starts with real device ID/service status and can read
existing peers and options without mutating them.

## Milestone 1: Workspace and Peers

1. Replace demo identity, service health, updates, and notifications with model
   data and real status/error/loading states.
2. Replace the static device grid with Recent, Favorites, Discovered, Address
   Book, and Group data sources.
3. Preserve peer search, sort, refresh, tags, aliases, context actions, and
   address book/group synchronization.
4. Wire Quick Connect and command palette to the existing connection flow,
   including passwords, tokens, relay preference, and connection failures.

Acceptance: peer updates are reflected live and every peer action invokes the
same FFI action as the legacy UI.

## Milestone 2: Session and Desktop Control

1. Build a session coordinator around the existing FFI lifecycle, connection
   permissions, reconnect/disconnect states, and tab/window selection.
2. Replace the desktop placeholder with the native render texture and remote
   cursor/display selection pipeline.
3. Migrate keyboard, mouse, touch, clipboard, relative mouse, scaling,
   resolution, privacy mode, recording, audio, and toolbar menus.
4. Preserve Wayland/macOS focus and input safeguards from the legacy flow.

Acceptance: a real desktop session supports input, clipboard, display changes,
reconnect, permission changes, and clean close/reconnect cycles.

## Milestone 3: Session Tools

1. Migrate the two-pane file manager, upload/download queue, file operations,
   drag and drop, breadcrumbs, search, conflict dialogs, and transfer progress.
2. Migrate terminal tabs using the existing terminal connection manager and
   terminal model lifecycle.
3. Migrate camera viewing, chat, voice/audio selection, and session overlays.
4. Migrate port forwarding/RDP, including create/edit/delete rules and FFI
   lifecycle management.

Acceptance: each tool opens through the existing window/tab event and works
with multiple concurrent peers without leaking an FFI session.

## Milestone 4: Settings and Account

1. Map every Aurora setting to its existing option key and remove local-only
   demo state.
2. Restore General, Security, Network, Display, Plugin, Account, Printer, and
   About pages with `SettingsTabKey` deep-link support.
3. Restore trusted devices, password/2FA, OIDC/account login, permissions,
   ID/relay server, proxy, UDP/WebSocket/TLS options, plugins, printer, and
   version/license/fingerprint data.
4. Keep the compact Aurora select/submenu controls while preserving policy
   locks and platform-specific visibility.

Acceptance: settings persist through restart, obey managed/fixed options, and
open the correct page from existing deep links.

## Milestone 5: Platform Parity

1. Restore desktop tab groups, multi-window creation, window titles, window
   position/fullscreen recovery, and close audits.
2. Restore mobile service status, Android/iOS permissions, QR server setup,
   scanner, floating mouse, gestures, and mobile-specific session controls.
3. Restore web feature gates and supported browser behavior without importing
   desktop-only dependencies.

Acceptance: desktop, Android/iOS, and web each expose only supported controls
and retain their legacy connection/window behavior.

## Quality Gates

- Add adapter tests for option keys, FFI calls, and model-to-view mapping.
- Add widget tests for loading/error/empty states, settings deep links, menu
  keyboard focus, desktop/mobile breakpoints, RTL, and long translations.
- Add integration smoke tests for remote desktop, file transfer, terminal,
  camera, port forwarding, chat, multi-window, reconnect, and close cleanup.
- Run `flutter analyze`, Flutter tests, a macOS build, and target-platform
  manual smoke tests for every completed milestone.

## Delivery Order

Do not start visual polish for a placeholder feature. Complete Milestone 0,
then deliver Milestones 1 through 5 in order. Keep the legacy source until all
acceptance criteria are met and a release candidate has passed regression
testing.
