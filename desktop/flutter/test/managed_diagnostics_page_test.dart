import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/features/workspace/managed_diagnostics_page.dart';
import 'package:flutter_hbb/integration/adapters/managed_client_adapter.dart';

void main() {
  testWidgets('retained diagnostics page updates live and copies', (tester) async {
    var error = 'invalid_config_response';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = call.arguments['text'] as String;
      return null;
    });
    final adapter = ManagedClientAdapter(statusReader: () async => jsonEncode({
      'managed_only': true, 'state': 'waiting_for_admin',
      'last_error': error, 'policy_state': 'unavailable',
    }));
    await tester.pumpWidget(CupertinoApp(
        home: ManagedDiagnosticsPage(adapter: adapter)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last error: invalid_config_response'), findsWidgets);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains('invalid_config_response'));
    expect(find.text('Copied'), findsOneWidget);
    error = 'owner_unavailable';
    await adapter.refresh();
    await tester.pump();
    expect(find.textContaining('Last error: owner_unavailable'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
