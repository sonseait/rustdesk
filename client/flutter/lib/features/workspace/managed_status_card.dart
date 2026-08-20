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
    return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: CupertinoColors.systemBackground.resolveFrom(context),
            borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(revoked ? LucideIcons.triangleAlert : LucideIcons.shieldCheck,
                size: 18,
                color: revoked
                    ? CupertinoColors.systemRed
                    : CupertinoTheme.of(context).primaryColor),
            const SizedBox(width: 8),
            const Text('Managed device',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(status.state)
          ]),
          const SizedBox(height: 8),
          Text(
              status.enrolled
                  ? 'This device is enrolled with ${status.controlPlaneUrl}.'
                  : revoked
                      ? 'This device was revoked. Enroll again with a new token.'
                      : 'Enroll this device to use managed access.',
              style: const TextStyle(fontSize: 12)),
          if (status.enrolled && status.credentialExpiresAt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Managed access expires: ${status.credentialExpiresAt}',
                style: const TextStyle(fontSize: 12)),
          ],
          if (status.enrolled) ...[
            const SizedBox(height: 4),
            Text(
              status.policyState == 'active'
                  ? 'Offline policy valid until: ${status.policyExpiresAt}'
                  : 'Offline policy is unavailable. New managed sessions are blocked.',
              style: const TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          if (status.enrolled)
            Wrap(spacing: 8, children: [
              CupertinoButton.filled(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  onPressed: _renewCredential,
                  child: const Text('Renew managed access')),
              CupertinoButton(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  onPressed: _heartbeat,
                  child: const Text('Refresh status')),
            ])
          else
            CupertinoButton.filled(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                onPressed: _enroll,
                child: const Text('Enroll device')),
          if (status.enrolled)
            CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _deprovision,
                child: const Text('Remove managed enrollment'))
        ]));
  }

  Future<void> _heartbeat() async {
    try {
      await adapter.heartbeat();
    } catch (_) {
      if (mounted) setState(() {});
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
