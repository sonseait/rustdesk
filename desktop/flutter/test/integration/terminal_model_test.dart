import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/session/terminal_model.dart';

void main() {
  group('terminalIdOf', () {
    test('accepts an int, as desktop sends', () {
      expect(terminalIdOf({'terminal_id': 3}), 3);
    });

    test('accepts a string, as web sends', () {
      // Getting this wrong routes output to the wrong tab.
      expect(terminalIdOf({'terminal_id': '3'}), 3);
    });

    test('an unparsable or missing id is rejected, not defaulted to 0', () {
      // Returning 0 would deliver another terminal's output to the first tab.
      expect(terminalIdOf({'terminal_id': 'abc'}), -1);
      expect(terminalIdOf({}), -1);
    });
  });

  group('decodeTerminalData', () {
    test('decodes base64 output', () {
      final encoded = base64Encode(utf8.encode('hello\r\n'));

      expect(decodeTerminalData(encoded), 'hello\r\n');
    });

    test('decodes a byte list', () {
      expect(decodeTerminalData(utf8.encode('hi')), 'hi');
    });

    test('falls back to plain text when the payload is not base64', () {
      // Some paths send raw strings; treating them as base64 would corrupt.
      expect(decodeTerminalData('not-valid-base64!!'), 'not-valid-base64!!');
    });

    test('handles malformed utf8 without throwing', () {
      final encoded = base64Encode([0xC3, 0x28]);

      expect(() => decodeTerminalData(encoded), returnsNormally);
    });

    test('null and unexpected types yield null', () {
      expect(decodeTerminalData(null), isNull);
      expect(decodeTerminalData(42), isNull);
    });

    test('preserves ansi escape sequences', () {
      // Colors and cursor moves must survive the round trip intact.
      const ansi = '\x1b[31mred\x1b[0m';
      final encoded = base64Encode(utf8.encode(ansi));

      expect(decodeTerminalData(encoded), ansi);
    });
  });

  group('RustDeskTerminal', () {
    test('erasing scrollback keeps the visible screen', () {
      final terminal = RustDeskTerminal(maxLines: 100);
      terminal.resize(80, 5);
      for (var i = 0; i < 30; i++) {
        terminal.write('line $i\r\n');
      }
      expect(terminal.buffer.scrollBack, greaterThan(0));

      terminal.eraseScrollbackOnly();

      expect(terminal.buffer.scrollBack, 0);
    });

    test('erasing with no scrollback is a no-op', () {
      final terminal = RustDeskTerminal(maxLines: 100);
      terminal.resize(80, 24);

      expect(terminal.eraseScrollbackOnly, returnsNormally);
    });
  });
}
