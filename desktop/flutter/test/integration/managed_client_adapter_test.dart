import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/integration/adapters/managed_client_adapter.dart';

void main() {
  test('owner read failure preserves confirmed revoked state', () async {
    var fail = false;
    final adapter = ManagedClientAdapter(statusReader: () async {
      if (fail) throw StateError('synthetic owner unavailable');
      return jsonEncode({'managed_only': true, 'state': 'revoked', 'device_id': 'synthetic'});
    });
    await adapter.refresh();
    fail = true;
    await adapter.refresh();
    expect(adapter.status.state, 'revoked');
    expect(adapter.status.ready, isFalse);
    adapter.dispose();
  });

  testWidgets('polling reads revoked updates and stops after disposal', (tester) async {
    var reads = 0;
    final adapter = ManagedClientAdapter(pollInterval: const Duration(seconds: 1), statusReader: () async {
      reads++;
      return jsonEncode({'managed_only': true, 'state': 'revoked'});
    });
    adapter.addListener(() {});
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 1);
    expect(adapter.status.state, 'revoked');
    adapter.dispose();
    await tester.pump(const Duration(seconds: 3));
    expect(reads, 1);
  });

  test('disposal cancels publication of an in-flight read', () async {
    final reply = Completer<String>();
    final adapter = ManagedClientAdapter(statusReader: () => reply.future);
    var notifications = 0;
    adapter.addListener(() { notifications++; });
    final refreshing = adapter.refresh();
    adapter.dispose();
    reply.complete('{"state":"ready"}');
    await refreshing;
    expect(notifications, 0);
  });
}
