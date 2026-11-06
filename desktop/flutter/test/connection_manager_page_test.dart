import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/features/launcher/connection_manager_page.dart';
import 'package:flutter_hbb/integration/adapters/mobile_service_adapter.dart';

class _Clients extends MobileServiceAdapter {
  bool succeeds = true;
  @override
  Future<void> refreshClients() async { clientsRefreshSucceeded = succeeds; }
}

void main() {
  testWidgets('closes only after the last incoming connection disappears',
      (tester) async {
    final adapter = _Clients();
    var closed = 0;
    await tester.pumpWidget(CupertinoApp(home: ConnectionManagerPage(
      adapter: adapter, onEmpty: () async { closed++; },
    )));
    await tester.pump();
    expect(closed, 0);
    adapter.setClientsForTest([
      const ConnectedClient(id: 1, peerId: '123', name: 'Workstation'),
    ]);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('Awaiting approval'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    adapter.setClientsForTest([]);
    adapter.succeeds = false;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(closed, 0);
    adapter.succeeds = true;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(closed, 1);
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });
}
