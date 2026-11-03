import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';

void main() {
  group('uriToCmdArgs', () {
    test('a bare link means show the window', () {
      expect(uriToCmdArgs(Uri.parse('rustdesk://')), isEmpty);
      expect(uriToCmdArgs(Uri.parse('rustdesk:///')), isEmpty);
      expect(uriToCmdArgs(Uri.parse('rustdesk://///')), isEmpty);
    });

    test('a bare id connects', () {
      expect(uriToCmdArgs(Uri.parse('rustdesk://123456789')),
          ['--connect', '123456789']);
    });

    test('the /r and /r@server suffixes stay part of the id', () {
      expect(uriToCmdArgs(Uri.parse('rustdesk://123456789/r')),
          ['--connect', '123456789/r']);
      expect(uriToCmdArgs(Uri.parse('rustdesk://123456789/r@example.com')),
          ['--connect', '123456789/r@example.com']);
    });

    test('every command authority maps to its flag', () {
      const cases = {
        'connect': '--connect',
        'play': '--play',
        'file-transfer': '--file-transfer',
        'view-camera': '--view-camera',
        'port-forward': '--port-forward',
        'rdp': '--rdp',
        'terminal': '--terminal',
        'terminal-admin': '--terminal-admin',
      };
      for (final entry in cases.entries) {
        expect(
          uriToCmdArgs(Uri.parse('rustdesk://${entry.key}/123')),
          [entry.value, '123'],
          reason: entry.key,
        );
      }
    });

    test('the legacy connection/new/ form still works', () {
      expect(uriToCmdArgs(Uri.parse('rustdesk://connection/new/123456789')),
          ['--connect', '123456789']);
    });

    test('the key query parameter is folded into the id', () {
      expect(uriToCmdArgs(Uri.parse('rustdesk://123456789?key=abc')),
          ['--connect', '123456789?key=abc']);
    });

    test('password and relay become flags', () {
      final args =
          uriToCmdArgs(Uri.parse('rustdesk://123?password=secret&relay=1'));

      expect(args, contains('--password'));
      expect(args![args.indexOf('--password') + 1], 'secret');
      expect(args, contains('--relay'));
    });

    test('query parameter names are case-insensitive', () {
      final args = uriToCmdArgs(Uri.parse('rustdesk://123?PASSWORD=secret'));
      expect(args, contains('--password'));
    });

    test('provisioning deep links are not connection requests', () {
      expect(uriToCmdArgs(Uri.parse('rustdesk://config/abc')), isNull);
      expect(uriToCmdArgs(Uri.parse('rustdesk://password/abc')), isNull);

      expect(isDeepLinkConfigOrPassword(Uri.parse('rustdesk://config/abc')),
          isTrue);
      expect(
          isDeepLinkConfigOrPassword(Uri.parse('rustdesk://123')), isFalse);
    });

    test('an id that is too short is not treated as a connect target', () {
      expect(uriToCmdArgs(Uri.parse('rustdesk://ab')), isNull);
    });
  });

  group('parseCmdArgs', () {
    test('no arguments means show the window', () {
      final result = parseCmdArgs(const []);

      expect(result.showMainWindow, isTrue);
      expect(result.request, isNull);
      expect(result.isHandled, isTrue);
    });

    test('unrecognized arguments are not handled', () {
      final result = parseCmdArgs(const ['--something-else']);

      expect(result.isHandled, isFalse);
      expect(result.request, isNull);
    });

    test('each flag maps to its connection kind', () {
      const cases = {
        '--connect': ConnectionKind.remoteDesktop,
        '--play': ConnectionKind.remoteDesktop,
        '--file-transfer': ConnectionKind.fileTransfer,
        '--view-camera': ConnectionKind.viewCamera,
        '--port-forward': ConnectionKind.portForward,
        '--rdp': ConnectionKind.rdp,
        '--terminal': ConnectionKind.terminal,
      };
      for (final entry in cases.entries) {
        final result = parseCmdArgs([entry.key, '123']);
        expect(result.request?.kind, entry.value, reason: entry.key);
        expect(result.request?.peerId, '123', reason: entry.key);
      }
    });

    test('terminal-admin is flagged separately from terminal', () {
      final admin = parseCmdArgs(const ['--terminal-admin', '123']);

      expect(admin.request?.kind, ConnectionKind.terminal);
      expect(admin.request?.isTerminalAdmin, isTrue);

      final plain = parseCmdArgs(const ['--terminal', '123']);
      expect(plain.request?.isTerminalAdmin, isFalse);
    });

    test('collects password, switch uuid and relay', () {
      final result = parseCmdArgs(const [
        '--connect',
        '123',
        '--password',
        'secret',
        '--switch_uuid',
        'uuid-1',
        '--relay',
      ]);

      final request = result.request!;
      expect(request.peerId, '123');
      expect(request.password, 'secret');
      expect(request.switchUuid, 'uuid-1');
      expect(request.forceRelay, isTrue);
    });

    test('a trailing flag with no value does not crash', () {
      // The legacy parser indexed past the end here.
      expect(parseCmdArgs(const ['--connect']).isHandled, isFalse);
      expect(parseCmdArgs(const ['--connect', '123', '--password']).request,
          isNotNull);
    });

    test('the last connection flag wins', () {
      final result =
          parseCmdArgs(const ['--connect', '111', '--terminal', '222']);

      expect(result.request?.kind, ConnectionKind.terminal);
      expect(result.request?.peerId, '222');
    });
  });

  group('parseUriLink', () {
    test('parses a full link end to end', () {
      final result =
          parseUriLink(Uri.parse('rustdesk://123456789?password=pw&relay=1'));

      final request = result.request!;
      expect(request.kind, ConnectionKind.remoteDesktop);
      expect(request.peerId, '123456789');
      expect(request.password, 'pw');
      expect(request.forceRelay, isTrue);
    });

    test('a bare link asks for the main window', () {
      expect(parseUriLink(Uri.parse('rustdesk://')).showMainWindow, isTrue);
    });

    test('a provisioning link is not handled here', () {
      expect(parseUriLink(Uri.parse('rustdesk://config/x')).isHandled, isFalse);
    });
  });

  group('window routing', () {
    test('each kind opens the right window type', () {
      expect(ConnectionKind.remoteDesktop.windowType, WindowType.RemoteDesktop);
      expect(ConnectionKind.fileTransfer.windowType, WindowType.FileTransfer);
      expect(ConnectionKind.viewCamera.windowType, WindowType.ViewCamera);
      expect(ConnectionKind.portForward.windowType, WindowType.PortForward);
      // RDP is a port-forward session with a flag.
      expect(ConnectionKind.rdp.windowType, WindowType.PortForward);
      expect(ConnectionKind.terminal.windowType, WindowType.Terminal);
    });

    test('each kind uses the existing new-window event name', () {
      expect(ConnectionKind.remoteDesktop.newWindowEvent,
          kWindowEventNewRemoteDesktop);
      expect(ConnectionKind.fileTransfer.newWindowEvent,
          kWindowEventNewFileTransfer);
      expect(
          ConnectionKind.viewCamera.newWindowEvent, kWindowEventNewViewCamera);
      expect(ConnectionKind.portForward.newWindowEvent,
          kWindowEventNewPortForward);
      expect(ConnectionKind.rdp.newWindowEvent, kWindowEventNewPortForward);
      expect(ConnectionKind.terminal.newWindowEvent, kWindowEventNewTerminal);
    });

    test('only rdp sets the isRDP flag', () {
      const rdp = ConnectionRequest(
          kind: ConnectionKind.rdp, peerId: '1');
      const pf = ConnectionRequest(
          kind: ConnectionKind.portForward, peerId: '1');

      expect(rdp.isRDP, isTrue);
      expect(pf.isRDP, isFalse);
    });
  });
}
