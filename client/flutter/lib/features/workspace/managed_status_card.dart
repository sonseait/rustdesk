import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_hbb/integration/adapters/managed_client_adapter.dart';

class ManagedStatusCard extends StatefulWidget {
  const ManagedStatusCard({super.key});
  @override
  State<ManagedStatusCard> createState() => _ManagedStatusCardState();
}

class _ManagedStatusCardState extends State<ManagedStatusCard> {
  final adapter = ManagedClientAdapter.instance;
  String _syncError = '';
  @override
  void initState() {
    super.initState();
    adapter.addListener(_changed);
    adapter.refresh();
  }

  @override
  void dispose() {
    adapter.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = adapter.status;
    final revoked = status.state == 'revoked';
    final needsAttention = revoked || status.lastError.isNotEmpty;
    final statusLabel = status.enrolled
        ? 'Protected'
        : needsAttention
            ? 'Action needed'
            : 'Connecting';
    return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: CupertinoColors.systemBackground.resolveFrom(context),
            borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(
                needsAttention
                    ? LucideIcons.triangleAlert
                    : LucideIcons.shieldCheck,
                size: 18,
                color: needsAttention
                    ? CupertinoColors.systemRed
                    : CupertinoTheme.of(context).primaryColor),
            const SizedBox(width: 8),
            const Text('Managed device',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                    color: needsAttention
                        ? CupertinoColors.systemRed.withValues(alpha: 0.1)
                        : CupertinoTheme.of(context)
                            .primaryColor
                            .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(statusLabel,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: needsAttention
                            ? CupertinoColors.systemRed
                            : CupertinoTheme.of(context).primaryColor)))
          ]),
          const SizedBox(height: 8),
          Text(
              status.enrolled
                  ? 'This device is protected by your organization.'
                  : status.managedOnly
                      ? 'Setting up the secure managed connection. New connections stay blocked until this is complete.'
                      : revoked
                          ? 'This device no longer has managed access.'
                          : 'Enroll this device to use managed access.',
              style: const TextStyle(fontSize: 12)),
          if (needsAttention) ...[
            const SizedBox(height: 5),
            const Text('Please contact your administrator if this continues.',
                style:
                    TextStyle(fontSize: 12, color: CupertinoColors.systemRed)),
          ],
          const SizedBox(height: 8),
          if (status.enrolled)
            Row(mainAxisSize: MainAxisSize.min, children: [
              CupertinoButton.filled(
                  minimumSize: const Size(0, 30),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  onPressed: _renewCredential,
                  child: const Text('Renew', style: TextStyle(fontSize: 12))),
              const SizedBox(width: 6),
              CupertinoButton(
                  minimumSize: const Size(0, 30),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  onPressed: _heartbeat,
                  child: const Text('Sync', style: TextStyle(fontSize: 12))),
            ]),
          if (_syncError.isNotEmpty) ...[
            const SizedBox(height: 5),
            const Text('Could not refresh managed access. Please try again.',
                style:
                    TextStyle(fontSize: 12, color: CupertinoColors.systemRed)),
          ],
          if (!status.enrolled && !status.managedOnly)
            CupertinoButton.filled(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                onPressed: _enroll,
                child: const Text('Enroll', style: TextStyle(fontSize: 12))),
          if (status.enrolled && !status.managedOnly)
            CupertinoButton(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                onPressed: _deprovision,
                child: const Text('Remove enrollment',
                    style: TextStyle(fontSize: 11)))
        ]));
  }

  Future<void> _heartbeat() async {
    try {
      await adapter.heartbeat();
      if (mounted) setState(() => _syncError = '');
    } catch (error) {
      if (mounted) setState(() => _syncError = error.toString());
    }
  }

  Future<void> _renewCredential() async {
    try {
      await adapter.renewCredential();
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _deprovision() async {
    await adapter.deprovision();
  }

  Future<void> _enroll() async {
    final url = TextEditingController(text: adapter.status.controlPlaneUrl);
    final token = TextEditingController();
    final name = TextEditingController(text: 'RustDesk device');
    await showCupertinoDialog(
        context: context,
        builder: (context) => CupertinoAlertDialog(
                title: const Text('Enroll managed device'),
                content: Column(children: [
                  CupertinoTextField(
                      controller: url, placeholder: 'Control plane URL'),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                      controller: name, placeholder: 'Device name'),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                      controller: token,
                      placeholder: 'Enrollment token',
                      obscureText: true)
                ]),
                actions: [
                  CupertinoDialogAction(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.pop(context)),
                  CupertinoDialogAction(
                      isDefaultAction: true,
                      child: const Text('Enroll'),
                      onPressed: () async {
                        try {
                          await adapter.configure(url.text);
                          await adapter.enroll(token.text, name.text);
                          if (context.mounted) Navigator.pop(context);
                        } catch (_) {}
                      })
                ]));
  }
}
