import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/boot_config.dart';

void main() {
  group('BootConfig.parse on desktop', () {
    test('no args launches the main window', () {
      final config = BootConfig.parse(const [], desktop: true);

      expect(config.mode, LaunchMode.main);
      expect(config.appType, kAppTypeMain);
      expect(config.desktopType, DesktopType.main);
      expect(config.windowId, isNull);
      expect(config.isMainWindow, isTrue);
    });

    test('--cm launches the connection manager', () {
      final config = BootConfig.parse(const ['--cm'], desktop: true);

      expect(config.mode, LaunchMode.connectionManager);
      expect(config.appType, kAppTypeConnectionManager);
      expect(config.desktopType, DesktopType.cm);
    });

    test('--install launches the installer at any position', () {
      final config =
          BootConfig.parse(const ['--other', '--install'], desktop: true);

      expect(config.mode, LaunchMode.install);
      expect(config.appType, kAppTypeMain);
    });

    test('multi_window remote desktop keeps the app type contract', () {
      final args = [
        'multi_window',
        '3',
        jsonEncode({
          'type': WindowType.RemoteDesktop.index,
          'id': 'peer-123',
          'display': 1,
        }),
      ];

      final config = BootConfig.parse(args, desktop: true);

      expect(config.mode, LaunchMode.subWindow);
      expect(config.windowId, 3);
      expect(config.windowType, WindowType.RemoteDesktop);
      expect(config.appType, kAppTypeDesktopRemote);
      expect(config.desktopType, DesktopType.remote);
      expect(config.peerId, 'peer-123');
      expect(config.display, 1);
      // The legacy bootstrap injects the window id into the argument map.
      expect(config.windowArgs['windowId'], 3);
    });

    test('every window type maps to its legacy app type', () {
      const expected = {
        WindowType.RemoteDesktop: kAppTypeDesktopRemote,
        WindowType.FileTransfer: kAppTypeDesktopFileTransfer,
        WindowType.ViewCamera: kAppTypeDesktopViewCamera,
        WindowType.PortForward: kAppTypeDesktopPortForward,
        WindowType.Terminal: kAppTypeDesktopTerminal,
      };

      for (final entry in expected.entries) {
        final args = [
          'multi_window',
          '7',
          jsonEncode({'type': entry.key.index}),
        ];
        final config = BootConfig.parse(args, desktop: true);

        expect(config.windowType, entry.key);
        expect(config.appType, entry.value);
      }
    });

    test('window type indices match the serialized contract', () {
      // These indices cross the multi-window channel; reordering the enum
      // would silently open the wrong window.
      expect(WindowType.Main.index, 0);
      expect(WindowType.RemoteDesktop.index, 1);
      expect(WindowType.FileTransfer.index, 2);
      expect(WindowType.ViewCamera.index, 3);
      expect(WindowType.PortForward.index, 4);
      expect(WindowType.Terminal.index, 5);
      expect(5.windowType, WindowType.Terminal);
      expect(99.windowType, WindowType.Unknown);
    });

    test('empty multi_window arguments decode to just the window id', () {
      final config =
          BootConfig.parse(const ['multi_window', '2', ''], desktop: true);

      expect(config.mode, LaunchMode.subWindow);
      expect(config.windowId, 2);
      expect(config.windowArgs, {'windowId': 2});
      // No type means Unknown, which falls back to the main app type.
      expect(config.windowType, WindowType.Unknown);
      expect(config.appType, kAppTypeMain);
    });

    test('malformed multi_window json does not crash the launch', () {
      final config = BootConfig.parse(
          const ['multi_window', '4', 'not json'],
          desktop: true);

      expect(config.mode, LaunchMode.subWindow);
      expect(config.windowId, 4);
      expect(config.windowArgs, {'windowId': 4});
    });

    test('multi_window without a parsable id falls back to the main window',
        () {
      final config =
          BootConfig.parse(const ['multi_window', 'abc'], desktop: true);

      expect(config.mode, LaunchMode.main);
      expect(config.windowId, isNull);
    });
  });

  group('BootConfig.parse on mobile', () {
    test('ignores desktop arguments and runs the main app', () {
      final config = BootConfig.parse(const ['--cm'], desktop: false);

      expect(config.mode, LaunchMode.main);
      expect(config.appType, kAppTypeMain);
      expect(config.desktopType, DesktopType.main);
    });
  });

  group('sub window surface selection', () {
    // Regression: main() used to ignore LaunchMode.subWindow and render the
    // workspace again, so clicking Connect created a window that showed a
    // second workspace instead of the session.
    test('a remote desktop launch carries everything the session needs', () {
      final config = BootConfig.parse([
        'multi_window',
        '1',
        jsonEncode({
          'type': WindowType.RemoteDesktop.index,
          'id': '512189585',
          'password': 'pw',
          'forceRelay': false,
        }),
      ], desktop: true);

      expect(config.mode, LaunchMode.subWindow);
      expect(config.windowType, WindowType.RemoteDesktop);
      expect(config.windowId, 1);
      expect(config.peerId, '512189585');
      expect(config.windowArgs['password'], 'pw');
      // The workspace must not be the surface for this launch.
      expect(config.isMainWindow, isFalse);
    });

    test('a file transfer launch is distinguishable from remote desktop', () {
      final config = BootConfig.parse([
        'multi_window',
        '2',
        jsonEncode({
          'type': WindowType.FileTransfer.index,
          'id': '512189585',
        }),
      ], desktop: true);

      expect(config.windowType, WindowType.FileTransfer);
      expect(config.isMainWindow, isFalse);
    });
  });
}
