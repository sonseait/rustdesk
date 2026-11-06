import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/session/session_adapter.dart';

class _Core implements RustdeskImpl {
  final events = StreamController<EventToUI>();
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sessionAddSync) return '';
    if (invocation.memberName == #sessionStart) return events.stream;
    if (invocation.memberName == #sessionClose ||
        invocation.memberName == #sessionReconnect) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test('connection progress follows transport and peer events', () async {
    final core = _Core();
    final session = SessionAdapter(peerId: '123', bindOverride: core);
    await session.start();
    expect(session.connectionProgress, contains('123'));
    core.events.add(EventToUI_Event(jsonEncode({
      'name': 'connection_ready', 'secure': 'true', 'direct': 'false',
    })));
    await Future<void>.delayed(Duration.zero);
    expect(session.connectionProgress, contains('Encrypted relay'));
    core.events.add(EventToUI_Event(jsonEncode({'name': 'peer_info'})));
    await Future<void>.delayed(Duration.zero);
    expect(session.connectionProgress, contains('first frame'));
    await session.reconnect();
    expect(session.connectionProgress, contains('Waiting for a connection'));
    expect(session.connectionProgress, isNot(contains('Encrypted relay')));
    await core.events.close();
    session.dispose();
  });
}
