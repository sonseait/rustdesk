import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/integration/session/chat_model.dart';
import 'package:flutter_hbb/integration/session/port_forward_model.dart';

void main() {
  group('ChatModel', () {
    ChatModel model() => ChatModel(
          sessionId: const Uuid().v4obj(),
          clock: () => DateTime.utc(2026),
        );

    test('starts empty with nothing unread', () {
      final chat = model();

      expect(chat.isEmpty, isTrue);
      expect(chat.unreadCount, 0);
    });

    test('records an incoming message and counts it unread', () {
      final chat = model();

      final handled =
          chat.handleEvent({'name': 'chat_client_mode', 'text': 'hello'});

      expect(handled, isTrue);
      expect(chat.messages.single.text, 'hello');
      expect(chat.messages.single.author, ChatAuthor.peer);
      expect(chat.unreadCount, 1);
    });

    test('ignores events that are not chat', () {
      final chat = model();

      expect(chat.handleEvent({'name': 'peer_info'}), isFalse);
      expect(chat.isEmpty, isTrue);
    });

    test('ignores an empty incoming message', () {
      final chat = model();

      chat.handleEvent({'name': 'chat_client_mode', 'text': ''});

      expect(chat.isEmpty, isTrue);
      expect(chat.unreadCount, 0);
    });

    test('marking read clears the badge but keeps the history', () {
      final chat = model()
        ..handleEvent({'name': 'chat_client_mode', 'text': 'hi'});

      chat.markRead();

      expect(chat.unreadCount, 0);
      expect(chat.messages.length, 1);
    });

    test('clear drops everything', () {
      final chat = model()
        ..handleEvent({'name': 'chat_client_mode', 'text': 'hi'});

      chat.clear();

      expect(chat.isEmpty, isTrue);
      expect(chat.unreadCount, 0);
    });
  });

  group('parseForwards', () {
    test('parses the positional array the peer config uses', () {
      final config = jsonEncode({
        'port_forwards': [
          [8080, 'localhost', 80],
          [2222, '10.0.0.5', 22],
        ],
      });

      final forwards = parseForwards(config);

      expect(forwards.length, 2);
      expect(forwards.first.localPort, 8080);
      expect(forwards.first.remoteHost, 'localhost');
      expect(forwards.first.remotePort, 80);
      expect(forwards.last.remoteHost, '10.0.0.5');
    });

    test('a peer with no rules yields an empty list', () {
      expect(parseForwards(jsonEncode({'id': '123'})), isEmpty);
      expect(parseForwards(jsonEncode({'port_forwards': []})), isEmpty);
    });

    test('malformed input yields empty rather than throwing', () {
      // A peer config that cannot be read means "nothing to show", not a
      // crash in the port forward panel.
      expect(parseForwards(''), isEmpty);
      expect(parseForwards('not json'), isEmpty);
      expect(parseForwards(jsonEncode([1, 2, 3])), isEmpty);
    });

    test('skips entries that are the wrong shape', () {
      final config = jsonEncode({
        'port_forwards': [
          [8080, 'localhost', 80],
          [1],
          'nonsense',
          [null, 'host', 'port'],
        ],
      });

      final forwards = parseForwards(config);

      // Only the well-formed rule survives; legacy would have thrown here.
      expect(forwards.length, 1);
      expect(forwards.single.localPort, 8080);
    });
  });

  group('PortForward', () {
    test('compares by value', () {
      const a = PortForward(localPort: 1, remoteHost: 'h', remotePort: 2);
      const b = PortForward(localPort: 1, remoteHost: 'h', remotePort: 2);
      const c = PortForward(localPort: 9, remoteHost: 'h', remotePort: 2);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('describes the tunnel direction', () {
      const forward =
          PortForward(localPort: 8080, remoteHost: 'db', remotePort: 5432);

      expect(forward.toString(), 'localhost:8080 → db:5432');
    });
  });
}
