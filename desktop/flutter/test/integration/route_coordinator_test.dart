import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/route_coordinator.dart';

void main() {
  late RouteCoordinator coordinator;

  setUp(() {
    coordinator = RouteCoordinator();
  });

  const request = ConnectionRequest(
    kind: ConnectionKind.remoteDesktop,
    peerId: '123456789',
  );

  group('event queueing', () {
    test('a request arriving before attach is queued, not dropped', () async {
      // Cold start: the link lands before the workspace is mounted.
      await coordinator.handleUri(Uri.parse('rustdesk://123456789'));

      expect(coordinator.pendingRequests.length, 1);
      expect(coordinator.pendingRequests.single.peerId, '123456789');
    });

    test('attaching drains queued requests in order', () async {
      await coordinator.handleUri(Uri.parse('rustdesk://111'));
      await coordinator.handleUri(Uri.parse('rustdesk://222'));

      final received = <String>[];
      await coordinator.attach(
        onConnectionRequest: (r) async => received.add(r.peerId),
      );

      expect(received, ['111', '222']);
      expect(coordinator.pendingRequests, isEmpty);
    });

    test('requests after attach go straight through', () async {
      final received = <String>[];
      await coordinator.attach(
        onConnectionRequest: (r) async => received.add(r.peerId),
      );

      await coordinator.handleUri(Uri.parse('rustdesk://333'));

      expect(received, ['333']);
      expect(coordinator.pendingRequests, isEmpty);
    });

    test('a queued show-window request is delivered on attach', () async {
      await coordinator.handleUri(Uri.parse('rustdesk://'));
      expect(coordinator.pendingShowMainWindow, isTrue);

      var shown = false;
      await coordinator.attach(onShowMainWindow: () async => shown = true);

      expect(shown, isTrue);
      expect(coordinator.pendingShowMainWindow, isFalse);
    });

    test('detach stops delivery and re-queues later events', () async {
      final received = <String>[];
      await coordinator.attach(
        onConnectionRequest: (r) async => received.add(r.peerId),
      );
      coordinator.detach();

      await coordinator.handleUri(Uri.parse('rustdesk://444'));

      expect(received, isEmpty);
      expect(coordinator.pendingRequests.single.peerId, '444');
    });

    test('an unhandled link neither queues nor dispatches', () async {
      final handled =
          await coordinator.handleUri(Uri.parse('rustdesk://config/abc'));

      expect(handled, isFalse);
      expect(coordinator.pendingRequests, isEmpty);
      expect(coordinator.pendingShowMainWindow, isFalse);
    });

    test('handleUri reports whether the link was consumed', () async {
      expect(await coordinator.handleUri(Uri.parse('rustdesk://123456789')),
          isTrue);
      expect(await coordinator.handleUri(Uri.parse('rustdesk://')), isTrue);
      expect(await coordinator.handleUri(Uri.parse('rustdesk://config/x')),
          isFalse);
    });

    test('the scheme is not checked, so custom client prefixes work', () {
      // Custom clients register their own scheme via mainUriPrefixSync, so
      // the parser matches on authority and path only. Adding a scheme check
      // here would break those builds.
      final custom = uriToCmdArgs(Uri.parse('acme://123456789'));
      final stock = uriToCmdArgs(Uri.parse('rustdesk://123456789'));

      expect(custom, stock);
    });

    test('resetForTest clears queued state', () async {
      await coordinator.handleUri(Uri.parse('rustdesk://555'));
      expect(coordinator.pendingRequests, isNotEmpty);

      coordinator.resetForTest();

      expect(coordinator.pendingRequests, isEmpty);
      expect(coordinator.pendingShowMainWindow, isFalse);
    });
  });

  group('request identity', () {
    test('requests compare by value so duplicates are detectable', () {
      const a = ConnectionRequest(
          kind: ConnectionKind.remoteDesktop, peerId: '1', password: 'pw');
      const b = ConnectionRequest(
          kind: ConnectionKind.remoteDesktop, peerId: '1', password: 'pw');
      const c = ConnectionRequest(
          kind: ConnectionKind.fileTransfer, peerId: '1', password: 'pw');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('the default request carries no relay preference', () {
      expect(request.forceRelay, isFalse);
      expect(request.password, isNull);
      expect(request.isTerminalAdmin, isFalse);
    });
  });
}
