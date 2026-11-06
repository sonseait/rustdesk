import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/integration/adapters/mobile_service_adapter.dart';

/// Approvals and active incoming connections for the native `--cm` process.
class ConnectionManagerPage extends StatefulWidget {
  const ConnectionManagerPage({super.key, this.adapter, this.onEmpty});

  final MobileServiceAdapter? adapter;
  final Future<void> Function()? onEmpty;

  @override
  State<ConnectionManagerPage> createState() => _ConnectionManagerPageState();
}

class _ConnectionManagerPageState extends State<ConnectionManagerPage> {
  late final _clients = widget.adapter ?? MobileServiceAdapter.instance;
  Timer? _timer;
  bool _refreshing = false;
  bool _hadClients = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || _closing) return;
    _refreshing = true;
    try {
      await _clients.refreshClients();
      if (!mounted) return;
      final active = _clients.clients.where((c) => !c.disconnected);
      // Initial empty IPC state or a failed read must not close an approval window.
      if (_clients.clientsRefreshSucceeded) {
        if (active.isNotEmpty) {
          _hadClients = true;
        } else if (_hadClients) {
          _closing = true;
          try {
            if (widget.onEmpty != null) {
              await widget.onEmpty!();
            } else {
              await windowManager.close();
            }
          } catch (error) {
            _closing = false;
            debugPrint('Could not close connection manager: $error');
          }
        }
      }
      if (mounted) setState(() {});
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final clients = _clients.clients.where((c) => !c.disconnected).toList();
    final pending = clients.where((c) => !c.authorized).length;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(context),
      child: SafeArea(child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(children: [
            Icon(LucideIcons.monitor, size: 22,
                color: CupertinoTheme.of(context).primaryColor),
            const SizedBox(width: 10),
            const Expanded(child: Text('Incoming connections',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
            Text('${clients.length}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
          ]),
          const SizedBox(height: 6),
          Text(pending > 0 ? '$pending awaiting approval' : 'Manage access to this device',
              style: const TextStyle(fontSize: 12, color: CupertinoColors.secondaryLabel)),
          const SizedBox(height: 20),
          if (clients.isEmpty)
            const Padding(padding: EdgeInsets.all(32),
                child: Center(child: Text('No incoming connections',
                    style: TextStyle(fontSize: 12, color: CupertinoColors.secondaryLabel)))),
          for (final client in clients)
            _ClientTile(key: ValueKey(client.id), client: client, adapter: _clients, onRefresh: _refresh),
        ],
      )),
    );
  }
}

class _ClientTile extends StatefulWidget {
  const _ClientTile({super.key, required this.client, required this.adapter, required this.onRefresh});
  final ConnectedClient client;
  final MobileServiceAdapter adapter;
  final Future<void> Function() onRefresh;

  @override
  State<_ClientTile> createState() => _ClientTileState();
}

class _ClientTileState extends State<_ClientTile> {
  bool _busy = false;

  Future<void> _act(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final permissions = [
      if (client.keyboard) 'Input',
      if (client.clipboard) 'Clipboard',
      if (client.file) 'Files',
      if (client.audio) 'Audio',
      if (client.recording) 'Recording',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CupertinoColors.separator.resolveFrom(context), width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(client.authorized ? 'Connected' : 'Awaiting approval',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                color: client.authorized ? CupertinoColors.systemGreen : CupertinoColors.systemOrange)),
        const SizedBox(height: 8),
        Text(client.displayName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('${client.peerId} · ${client.toolLabel}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12,
                color: CupertinoColors.secondaryLabel)),
        if (client.authorized && permissions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(permissions.join(' · '), style: const TextStyle(fontSize: 11,
              color: CupertinoColors.secondaryLabel)),
        ],
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (_busy) const Padding(padding: EdgeInsets.only(right: 8),
              child: CupertinoActivityIndicator(radius: 8)),
          CupertinoButton(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            onPressed: _busy ? null : () => _act(() => client.authorized
                ? widget.adapter.disconnectClient(client)
                : widget.adapter.respondToClient(client, false)),
            child: Text(client.authorized ? 'Disconnect' : 'Refuse',
                style: const TextStyle(fontSize: 12, color: CupertinoColors.systemRed)),
          ),
          if (!client.authorized) ...[
            const SizedBox(width: 8),
            CupertinoButton.filled(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              onPressed: _busy ? null : () => _act(() => widget.adapter.respondToClient(client, true)),
              child: const Text('Accept', style: TextStyle(fontSize: 12)),
            ),
          ],
        ]),
      ]),
    );
  }
}
