import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/features/workspace/settings_view_model.dart';

void main() {
  const config = ServerConfig(
    idServer: 'id.example.com',
    relayServer: 'relay.example.com',
    apiServer: 'https://api.example.com',
    key: 'abcdef',
  );

  group('sharing a configuration', () {
    test('survives a round trip', () {
      final decoded = ServerConfig.decode(config.encode());

      expect(decoded.idServer, config.idServer);
      expect(decoded.relayServer, config.relayServer);
      expect(decoded.apiServer, config.apiServer);
      expect(decoded.key, config.key);
    });

    test('uses the short keys the server writes', () {
      // These are the server's field names, not this model's. Renaming one
      // makes every existing QR code unreadable.
      final reversed = config.encode().split('').reversed.join();
      final json = jsonDecode(utf8.decode(base64Decode(
          base64.normalize(reversed)))) as Map<String, dynamic>;

      expect(json.keys.toSet(), {'host', 'relay', 'api', 'key'});
      expect(json['host'], 'id.example.com');
      expect(json['relay'], 'relay.example.com');
    });

    test('plain JSON from an older share is still accepted', () {
      // Older clients shared the JSON directly; those codes must keep working.
      final decoded = ServerConfig.decode(
          '{"host":"id.example.com","relay":"r.example.com","api":"","key":"k"}');

      expect(decoded.idServer, 'id.example.com');
      expect(decoded.relayServer, 'r.example.com');
      expect(decoded.key, 'k');
    });

    test('a missing field decodes as empty rather than throwing', () {
      final decoded = ServerConfig.decode('{"host":"id.example.com"}');

      expect(decoded.idServer, 'id.example.com');
      expect(decoded.apiServer, isEmpty);
    });

    test('nonsense is rejected rather than silently emptied', () {
      // Decoding garbage into an empty config would point the client at no
      // server at all, which looks like a successful scan.
      expect(() => ServerConfig.decode('not a config'), throwsA(anything));
    });

    test('the values are trimmed on the way out', () {
      const padded = ServerConfig(idServer: '  id.example.com  ');

      expect(ServerConfig.decode(padded.encode()).idServer, 'id.example.com');
    });
  });

  group('scanning a QR code', () {
    test('a configuration code is read', () {
      final scanned = config.toQrCode();

      expect(scanned.startsWith('config='), isTrue);
      expect(ServerConfig.fromQrCode(scanned)?.idServer, 'id.example.com');
    });

    test('an unrelated code is ignored', () {
      // A camera picks up whatever is in view; a URL or a wifi code must not
      // be parsed into a server configuration.
      expect(ServerConfig.fromQrCode('https://example.com'), isNull);
      expect(ServerConfig.fromQrCode(''), isNull);
    });

    test('a configuration code with a corrupt payload is ignored', () {
      // Returning null lets the scanner say the code was unreadable instead
      // of writing an empty configuration over the working one.
      expect(ServerConfig.fromQrCode('config=@@@not-base64@@@'), isNull);
    });
  });
}
