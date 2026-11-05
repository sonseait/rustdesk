import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/integration/adapters/managed_client_adapter.dart';

void main() {
  test('diagnostics deduplicate, bound history and exclude response secrets', () async {
    var revision = 0;
    final adapter = ManagedClientAdapter(statusReader: () async => jsonEncode({
      'state': 'waiting_for_admin', 'last_error': 'invalid_config_response',
      'control_plane_url': 'https://user:password@example.com/api?token=secret',
      'policy_expires_at': '$revision', 'signing_key': 'private-key',
      'enrollment_token': 'bootstrap-secret',
    }));
    await adapter.refresh();
    await adapter.refresh();
    expect(adapter.diagnosticEvents.length, 1);
    expect(adapter.diagnosticSummary, contains('invalid_config_response'));
    for (final secret in ['password', 'secret', 'private-key', 'user:']) {
      expect(adapter.diagnosticSummary, isNot(contains(secret)));
    }
    for (revision = 1; revision <= 110; revision++) {
      await adapter.refresh();
    }
    expect(adapter.diagnosticEvents.length, 100);
    expect(adapter.diagnosticEvents.first, contains('Policy expires: 110'));
    adapter.dispose();
  });
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
