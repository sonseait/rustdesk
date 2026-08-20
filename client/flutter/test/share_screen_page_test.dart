import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/features/workspace/share_screen_page.dart';
import 'package:flutter_hbb/integration/adapters/mobile_service_adapter.dart';

import 'support/fake_workspace_view_model.dart';

/// A sharing adapter over in-memory state.
///
/// The real one talks to the Android host, which a widget test has no channel
/// to. Only the transport is replaced; the state rules are the real ones.
class _FakeService extends MobileServiceAdapter {
  _FakeService({
    MobileServiceState state = const MobileServiceState(),
    List<ConnectedClient> clients = const [],
    this.servicePermissions = const [],
  }) {
    setStateForTest(state);
    setClientsForTest(clients);
  }

  final List<ServicePermission> servicePermissions;

  final List<String> requested = [];
  final List<(int, bool)> responses = [];
  final List<int> disconnected = [];
  var startCalls = 0;
  var stopCalls = 0;

  /// Whether starting should succeed. False stands in for a refused
  /// notification permission.
  bool canStart = true;

  @override
  Future<List<ServicePermission>> permissions() async => servicePermissions;

  @override
  Future<void> syncPermissions() async {}

  @override
  Future<void> refreshClients() async {}

  @override
  Future<bool> startService() async {
    startCalls++;
    if (!canStart) return false;
    setStateForTest(const MobileServiceState(isRunning: true));
    return true;
  }

  @override
  Future<void> stopService() async {
    stopCalls++;
    setStateForTest(const MobileServiceState());
  }

  @override
  Future<bool> requestPermission(String permission) async {
    requested.add(permission);
    return true;
  }

  @override
  Future<void> respondToClient(ConnectedClient client, bool accept) async =>
      responses.add((client.id, accept));

  @override
  Future<void> disconnectClient(ConnectedClient client) async =>
      disconnected.add(client.id);
}

ConnectedClient client(
  int id, {
  String peerId = '847293160',
  String name = 'Ada',
  bool authorized = true,
  bool isFileTransfer = false,
}) =>
    ConnectedClient(
      id: id,
      peerId: peerId,
      name: name,
      authorized: authorized,
      isFileTransfer: isFileTransfer,
    );

void main() {
  Future<_FakeService> pumpShare(
    WidgetTester tester, {
    _FakeService? service,
    FakeWorkspaceViewModel? workspace,
  }) async {
    final model = service ?? _FakeService();
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: ShareScreenPage(
          workspace: workspace ?? FakeWorkspaceViewModel(),
          service: model,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return model;
  }

  group('sharing state', () {
    testWidgets('a stopped service offers to start', (tester) async {
      final service = await pumpShare(tester);

      expect(find.text('Not sharing'), findsOneWidget);
      await tester.tap(find.text('Start sharing'));
      await tester.pumpAndSettle();

      expect(service.startCalls, 1);
      expect(find.text('Sharing this screen'), findsNothing,
          reason: 'the projection has not been granted yet');
    });

    testWidgets('a service with no screen access says so', (tester) async {
      // Android grants the projection separately, so this state is real:
      // calling it "sharing" would tell the user their screen is visible when
      // it is not.
      await pumpShare(tester,
          service: _FakeService(
              state: const MobileServiceState(isRunning: true)));

      expect(find.text('Waiting for screen access'), findsOneWidget);
      expect(find.textContaining('not granted screen capture'), findsOneWidget);
    });

    testWidgets('a fully running service reports sharing', (tester) async {
      await pumpShare(tester,
          service: _FakeService(
              state: const MobileServiceState(
                  isRunning: true, canCaptureScreen: true)));

      expect(find.text('Sharing this screen'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
    });

    testWidgets('stopping goes through the adapter', (tester) async {
      final service = await pumpShare(tester,
          service: _FakeService(
              state: const MobileServiceState(
                  isRunning: true, canCaptureScreen: true)));

      await tester.tap(find.text('Stop sharing'));
      await tester.pumpAndSettle();

      expect(service.stopCalls, 1);
      expect(find.text('Not sharing'), findsOneWidget);
    });
  });

  group('identity', () {
    testWidgets('shows the real id and one-time password', (tester) async {
      await pumpShare(tester);

      expect(find.text('847 293 160'), findsOneWidget);
      expect(find.text('RustDesk ID'), findsOneWidget);
    });
  });

  group('connections', () {
    testWidgets('no connections means no connections card', (tester) async {
      await pumpShare(tester);

      expect(find.text('Connections'), findsNothing);
    });

    testWidgets('a waiting connection can be accepted', (tester) async {
      // An unauthorised connection is a decision to make, not a session to
      // end, so it offers Accept and Refuse rather than Disconnect.
      final service = await pumpShare(tester,
          service: _FakeService(clients: [client(7, authorized: false)]));

      expect(find.textContaining('waiting for you'), findsOneWidget);
      expect(find.text('Disconnect'), findsNothing);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      expect(service.responses, [(7, true)]);
    });

    testWidgets('a waiting connection can be refused', (tester) async {
      final service = await pumpShare(tester,
          service: _FakeService(clients: [client(7, authorized: false)]));

      await tester.tap(find.text('Refuse'));
      await tester.pumpAndSettle();

      expect(service.responses, [(7, false)]);
    });

    testWidgets('an accepted connection can be disconnected', (tester) async {
      final service = await pumpShare(tester,
          service: _FakeService(clients: [client(9)]));

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Screen sharing'), findsOneWidget);

      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();

      expect(service.disconnected, [9]);
    });

    testWidgets('each connection says what it is doing', (tester) async {
      await pumpShare(tester,
          service: _FakeService(
              clients: [client(1, isFileTransfer: true, name: 'Ada')]));

      expect(find.text('File transfer'), findsOneWidget);
    });

    testWidgets('a nameless peer falls back to its id', (tester) async {
      await pumpShare(tester,
          service: _FakeService(
              clients: [client(1, name: '', peerId: '112233445')]));

      expect(find.text('112233445'), findsOneWidget);
    });
  });

  group('permissions', () {
    testWidgets('a granted permission needs no button', (tester) async {
      await pumpShare(tester,
          service: _FakeService(servicePermissions: const [
            ServicePermission(
                permission: 'android.permission.RECORD_AUDIO',
                granted: true,
                required: false)
          ]));

      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Granted'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
    });

    testWidgets('a missing optional permission says what it costs',
        (tester) async {
      // Refusing an optional permission should be an informed choice rather
      // than a mystery.
      await pumpShare(tester,
          service: _FakeService(servicePermissions: const [
            ServicePermission(
                permission: 'android.permission.RECORD_AUDIO',
                granted: false,
                required: false)
          ]));

      expect(find.textContaining('shares no sound'), findsOneWidget);
    });

    testWidgets('a missing required permission is marked required',
        (tester) async {
      await pumpShare(tester,
          service: _FakeService(servicePermissions: const [
            ServicePermission(
                permission: 'android.permission.POST_NOTIFICATIONS',
                granted: false,
                required: true)
          ]));

      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Required for sharing'), findsOneWidget);
    });

    testWidgets('asking for one goes through the adapter', (tester) async {
      final service = await pumpShare(tester,
          service: _FakeService(servicePermissions: const [
            ServicePermission(
                permission: 'android.permission.RECORD_AUDIO',
                granted: false,
                required: false)
          ]));

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(service.requested, ['android.permission.RECORD_AUDIO']);
    });
  });
}
