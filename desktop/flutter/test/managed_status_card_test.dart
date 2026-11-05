import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/features/workspace/managed_status_card.dart';
import 'package:flutter_hbb/integration/adapters/managed_client_adapter.dart';

class _ManagedClient extends ChangeNotifier implements ManagedClientAdapter {
  ManagedClientStatus? overrideStatus;
  int refreshCount = 0;
  SchedulerPhase? refreshPhase;

  @override
  ManagedClientStatus get status => overrideStatus ?? ManagedClientAdapter.instance.status;

  @override
  Future<void> refresh() async {
    refreshCount++;
    refreshPhase = SchedulerBinding.instance.schedulerPhase;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('unmanaged card retains manual enrollment', (tester) async {
    final adapter = _ManagedClient();
    await tester.pumpWidget(CupertinoApp(home: ManagedStatusCard(adapter: adapter)));
    await tester.pump();
    expect(find.text('Enroll'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
  });

  ManagedClientStatus managed(String state, {String credential = '', String policy = ''}) => ManagedClientStatus(
      state: state, managedOnly: true, deviceId: 'synthetic-device', controlPlaneUrl: '',
      rendezvousServer: '', relayServer: '', credentialExpiresAt: credential,
      policyExpiresAt: policy, policyState: 'active', lastError: '');

  testWidgets('managed card has no lifecycle buttons', (tester) async {
    final adapter = _ManagedClient()..overrideStatus = managed('enrolled');
    await tester.pumpWidget(CupertinoApp(home: ManagedStatusCard(adapter: adapter)));
    await tester.pump();
    for (final label in ['Enroll', 'Renew', 'Sync', 'Remove enrollment']) {
      expect(find.text(label), findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
  });

  testWidgets('expired access never says Protected', (tester) async {
    final adapter = _ManagedClient()..overrideStatus = managed('enrolled',
        credential: '2000-01-01T00:00:00Z', policy: '2000-01-01T00:00:00Z');
    await tester.pumpWidget(CupertinoApp(home: ManagedStatusCard(adapter: adapter)));
    await tester.pump();
    expect(find.text('Protected'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
  });

  testWidgets('revoked state is read only', (tester) async {
    final adapter = _ManagedClient()..overrideStatus = managed('revoked');
    await tester.pumpWidget(CupertinoApp(home: ManagedStatusCard(adapter: adapter)));
    await tester.pump();
    expect(find.text('Revoked'), findsOneWidget);
    expect(find.textContaining('Recovery is automatic'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
  });

  testWidgets('reconnecting explains automatic recovery', (tester) async {
    final adapter = _ManagedClient()..overrideStatus = managed('reconnecting');
    await tester.pumpWidget(CupertinoApp(home: ManagedStatusCard(adapter: adapter)));
    await tester.pump();
    expect(find.textContaining('automatically'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
  });

  testWidgets('missing revoked identity explains administrator enrollment', (tester) async {
    final adapter = _ManagedClient()..overrideStatus = const ManagedClientStatus(
      state: 'revoked', managedOnly: true, deviceId: '', controlPlaneUrl: '',
      rendezvousServer: '', relayServer: '', credentialExpiresAt: '',
      policyExpiresAt: '', policyState: 'unavailable', lastError: 'recovery_identity_missing');
    await tester.pumpWidget(CupertinoApp(home: ManagedStatusCard(adapter: adapter)));
    await tester.pump();
    expect(find.text('Recovery required'), findsOneWidget);
    expect(find.textContaining('enroll this device again'), findsOneWidget);
    expect(find.textContaining('Recovery is automatic'), findsNothing);
    expect(find.text('Diagnostics'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
  });

  testWidgets('initial refresh can notify an ancestor after build', (tester) async {
    final adapter = _ManagedClient();
    await tester.pumpWidget(CupertinoApp(
      home: _ListeningParent(adapter: adapter),
    ));

    expect(tester.takeException(), isNull);
    expect(adapter.refreshCount, 1);
    expect(adapter.refreshPhase, SchedulerPhase.postFrameCallbacks);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
  });
}

class _ListeningParent extends StatefulWidget {
  const _ListeningParent({required this.adapter});
  final _ManagedClient adapter;

  @override
  State<_ListeningParent> createState() => _ListeningParentState();
}

class _ListeningParentState extends State<_ListeningParent> {
  @override
  void initState() {
    super.initState();
    widget.adapter.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.adapter.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        child: ManagedStatusCard(adapter: widget.adapter),
      );
}
