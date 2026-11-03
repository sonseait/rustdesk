import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/features/workspace/scan_config_page.dart';
import 'package:flutter_hbb/features/workspace/settings_view_model.dart';

void main() {
  const config = ServerConfig(
    idServer: 'id.example.com',
    relayServer: 'relay.example.com',
    apiServer: 'https://api.example.com',
    key: 'abcdef',
  );

  Future<(GlobalKey<ScanConfigPageState>, List<ServerConfig>)> pumpScanner(
    WidgetTester tester,
  ) async {
    final key = GlobalKey<ScanConfigPageState>();
    final scanned = <ServerConfig>[];
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(CupertinoApp(
      home: ScanConfigPage(key: key, onScanned: scanned.add),
    ));
    await tester.pumpAndSettle();
    return (key, scanned);
  }

  group('before a code is read', () {
    testWidgets('explains what to point the camera at', (tester) async {
      await pumpScanner(tester);

      expect(find.textContaining('Point the camera'), findsOneWidget);
      expect(find.text('Use this server'), findsNothing);
    });

    testWidgets('a device with no camera says so', (tester) async {
      // The test host is not a phone, so this is the branch that renders.
      await pumpScanner(tester);

      expect(find.textContaining('no camera'), findsOneWidget);
    });
  });

  group('reading a code', () {
    testWidgets('an unrelated code is rejected, not parsed', (tester) async {
      // A camera picks up every code in view; a wifi or URL code must not
      // become an empty server configuration.
      final (key, scanned) = await pumpScanner(tester);

      key.currentState!.handleScan('https://example.com');
      await tester.pumpAndSettle();

      expect(find.textContaining('not a RustDesk configuration'),
          findsOneWidget);
      expect(scanned, isEmpty);
      expect(find.text('Use this server'), findsNothing);
    });

    testWidgets('a configuration is shown before it is applied',
        (tester) async {
      // A wrong server makes this client unreachable, and that is not obvious
      // afterwards, so the values are shown first.
      final (key, scanned) = await pumpScanner(tester);

      key.currentState!.handleScan(config.toQrCode());
      await tester.pumpAndSettle();

      expect(find.text('Configuration found'), findsOneWidget);
      expect(find.text('id.example.com'), findsOneWidget);
      expect(find.text('relay.example.com'), findsOneWidget);
      expect(scanned, isEmpty, reason: 'nothing is written until confirmed');
    });

    testWidgets('an empty field reads as not set', (tester) async {
      final (key, _) = await pumpScanner(tester);

      key.currentState!
          .handleScan(const ServerConfig(idServer: 'id.example.com')
              .toQrCode());
      await tester.pumpAndSettle();

      expect(find.text('Not set'), findsWidgets);
    });

    testWidgets('a second code is ignored while one is held', (tester) async {
      // The stream fires every frame the code stays in view; re-reading would
      // reset the confirmation the user is looking at.
      final (key, _) = await pumpScanner(tester);

      key.currentState!.handleScan(config.toQrCode());
      await tester.pumpAndSettle();
      key.currentState!.handleScan(
          const ServerConfig(idServer: 'other.example.com').toQrCode());
      await tester.pumpAndSettle();

      expect(find.text('id.example.com'), findsOneWidget);
      expect(find.text('other.example.com'), findsNothing);
    });
  });

  group('applying a configuration', () {
    testWidgets('confirming hands the configuration over', (tester) async {
      final (key, scanned) = await pumpScanner(tester);

      key.currentState!.handleScan(config.toQrCode());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this server'));
      await tester.pumpAndSettle();

      expect(scanned.single.idServer, 'id.example.com');
      expect(scanned.single.key, 'abcdef');
    });

    testWidgets('scanning again clears the held configuration',
        (tester) async {
      final (key, scanned) = await pumpScanner(tester);

      key.currentState!.handleScan(config.toQrCode());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan again'));
      await tester.pumpAndSettle();

      expect(find.text('Configuration found'), findsNothing);
      expect(find.textContaining('Point the camera'), findsOneWidget);
      expect(scanned, isEmpty);
    });
  });
}
