import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/integration/session/port_forward_model.dart';

/// Tunnels from a local port to a host on the peer's network.
class PortForwardView extends StatefulWidget {
  const PortForwardView({super.key, required this.model});

  final PortForwardModel model;

  @override
  State<PortForwardView> createState() => _PortForwardViewState();
}

class _PortForwardViewState extends State<PortForwardView> {
  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.model.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
              child: Text('Port forwarding',
                  style: TextStyle(
                      color: CupertinoColors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ),
            _SmallButton(
              icon: LucideIcons.monitorPlay,
              label: 'Open RDP',
              onTap: () => widget.model.openRdp(),
            ),
            const SizedBox(width: 7),
            _SmallButton(
              icon: LucideIcons.plus,
              label: 'Add tunnel',
              onTap: _promptForRule,
            ),
          ]),
          const SizedBox(height: 5),
          const Text(
              'Reach a service on the remote network through a port on this '
              'machine.',
              style: TextStyle(color: Color(0xFF9C8279), fontSize: 11)),
          const SizedBox(height: 14),
          Expanded(child: _body()),
        ]),
      );

  Widget _body() {
    final error = widget.model.error;
    if (error != null) {
      return _Message(
          icon: LucideIcons.triangleAlert,
          title: 'Could not read the tunnels',
          detail: '$error');
    }
    if (widget.model.isEmpty) {
      return const _Message(
          icon: LucideIcons.route,
          title: 'No tunnels yet',
          detail: 'Add one to forward a local port to the remote network.');
    }
    return ListView.builder(
      itemCount: widget.model.forwards.length,
      itemBuilder: (context, index) {
        final forward = widget.model.forwards[index];
        return _ForwardRow(
          forward: forward,
          onRemove: () => widget.model.remove(forward.localPort),
        );
      },
    );
  }

  Future<void> _promptForRule() async {
    final rule = await showCupertinoDialog<PortForward>(
      context: context,
      builder: (context) => const _AddTunnelDialog(),
    );
    if (rule == null) return;
    try {
      await widget.model.add(
        localPort: rule.localPort,
        remoteHost: rule.remoteHost,
        remotePort: rule.remotePort,
      );
    } catch (e) {
      if (!mounted) return;
      // A port already in use is rejected by the core, not by this form.
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Could not add the tunnel'),
          content: Text('$e'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}

class _ForwardRow extends StatelessWidget {
  const _ForwardRow({required this.forward, required this.onRemove});

  final PortForward forward;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF211613),
          border: Border.all(color: const Color(0xFF4A3029)),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(children: [
          const Icon(LucideIcons.route, size: 15, color: Color(0xFFF5B69B)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('localhost:${forward.localPort}',
                      style: const TextStyle(
                          color: CupertinoColors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('→ ${forward.remoteHost}:${forward.remotePort}',
                      style: const TextStyle(
                          color: Color(0xFF9C8279), fontSize: 11)),
                ]),
          ),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(LucideIcons.trash2,
                size: 14, color: Color(0xFF9C8279)),
          ),
        ]),
      );
}

/// Collects a new tunnel's ports and host.
class _AddTunnelDialog extends StatefulWidget {
  const _AddTunnelDialog();

  @override
  State<_AddTunnelDialog> createState() => _AddTunnelDialogState();
}

class _AddTunnelDialogState extends State<_AddTunnelDialog> {
  final _localPort = TextEditingController();
  final _remoteHost = TextEditingController(text: 'localhost');
  final _remotePort = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _localPort.dispose();
    _remoteHost.dispose();
    _remotePort.dispose();
    super.dispose();
  }

  void _submit() {
    final local = int.tryParse(_localPort.text.trim());
    final remote = int.tryParse(_remotePort.text.trim());
    final host = _remoteHost.text.trim();

    // Validate here so an obviously wrong rule never reaches the core.
    if (local == null || !_isValidPort(local)) {
      setState(() => _error = 'The local port must be between 1 and 65535.');
      return;
    }
    if (remote == null || !_isValidPort(remote)) {
      setState(() => _error = 'The remote port must be between 1 and 65535.');
      return;
    }
    if (host.isEmpty) {
      setState(() => _error = 'Enter a remote host.');
      return;
    }
    Navigator.of(context).pop(PortForward(
      localPort: local,
      remoteHost: host,
      remotePort: remote,
    ));
  }

  static bool _isValidPort(int port) => port > 0 && port <= 65535;

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
        title: const Text('Add a tunnel'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(children: [
            _field(_localPort, 'Local port', keyboard: TextInputType.number),
            const SizedBox(height: 8),
            _field(_remoteHost, 'Remote host'),
            const SizedBox(height: 8),
            _field(_remotePort, 'Remote port', keyboard: TextInputType.number),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(
                      color: CupertinoColors.systemRed, fontSize: 11)),
            ],
          ]),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: _submit,
            child: const Text('Add'),
          ),
        ],
      );

  Widget _field(TextEditingController controller, String placeholder,
          {TextInputType? keyboard}) =>
      CupertinoTextField(
        controller: controller,
        placeholder: placeholder,
        keyboardType: keyboard,
        onSubmitted: (_) => _submit(),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      );
}

class _SmallButton extends StatelessWidget {
  const _SmallButton(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF3B241C),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: const Color(0xFFF5DDD2)),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: Color(0xFFF5DDD2),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message(
      {required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 30, color: const Color(0xFFF5B69B)),
          const SizedBox(height: 10),
          Text(title,
              style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text(detail,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Color(0xFF9C8279), fontSize: 11)),
          ),
        ]),
      );
}
