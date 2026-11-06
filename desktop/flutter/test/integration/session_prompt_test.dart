import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/integration/session/session_adapter.dart';

void main() {
  test('direct connection relay hints are terminal connection errors', () {
    for (final type in ['relay-hint', 'relay-hint2']) {
      final prompt = SessionPrompt(
        type: type,
        title: 'Connection Error',
        text: 'deadline has elapsed',
      );
      expect(prompt.isError, isTrue, reason: type);
    }
  });
}
