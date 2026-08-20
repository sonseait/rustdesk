import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'package:flutter_hbb/integration/adapters/mobile_service_adapter.dart';

/// Desktop surface for the core's `--cm` process.
///
/// The client list uses the same connection-manager API as the mobile sharing
/// surface, but this process owns only approvals and disconnects.
class ConnectionManagerPage extends StatefulWidget {
  const ConnectionManagerPage({super.key});

  @override
  State<ConnectionManagerPage> createState() => _ConnectionManagerPageState();
}

class _ConnectionManagerPageState extends State<ConnectionManagerPage> {
  final _clients = MobileServiceAdapter.instance;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await _clients.refreshClients();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final clients = _clients.clients;
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Connection manager'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
                '${clients.length} active connection${clients.length == 1 ? '' : 's'}',
                style: CupertinoTheme.of(context).textTheme.navTitleTextStyle),
            const SizedBox(height: 12),
            if (clients.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: Text('No incoming connections')),
              ),
            for (final client in clients)
              _ClientTile(client: client, onRefresh: _refresh),
          ],
        ),
      ),
    );
  }
}

class _ClientTile extends StatelessWidget {
  const _ClientTile({required this.client, required this.onRefresh});

  final ConnectedClient client;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(client.displayName,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text('${client.peerId} - ${client.toolLabel}'),
          const SizedBox(height: 10),
          Row(children: [
            if (!client.authorized) ...[
              CupertinoButton.filled(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                onPressed: () async {
                  await MobileServiceAdapter.instance
                      .respondToClient(client, true);
                  await onRefresh();
                },
                child: const Text('Accept'),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                onPressed: () async {
                  await MobileServiceAdapter.instance
                      .respondToClient(client, false);
                  await onRefresh();
                },
                child: const Text('Refuse'),
              ),
            ] else
              CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                onPressed: () async {
                  await MobileServiceAdapter.instance.disconnectClient(client);
                  await onRefresh();
                },
                child: const Text('Disconnect'),
              ),
          ]),
        ]),
      );
}
