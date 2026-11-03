import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/features/common/aurora_surface.dart';
import 'package:flutter_hbb/features/workspace/workspace_view_model.dart';
import 'package:flutter_hbb/integration/adapters/mobile_service_adapter.dart';
import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// Sharing this device's screen, on a phone or tablet.
///
/// Ported from `ServerPage` in
/// `flutter_legacy/lib/mobile/pages/server_page.dart`. The distinction the
/// legacy page draws and this keeps: the service running and the screen
/// actually being captured are two different things, because Android grants
/// the media projection separately.
class ShareScreenPage extends StatefulWidget {
  const ShareScreenPage({
    super.key,
    required this.workspace,
    this.service,
  });

  /// Supplies the device id and its connection status.
  final WorkspaceViewModel workspace;

  /// Injectable for tests.
  final MobileServiceAdapter? service;

  @override
  State<ShareScreenPage> createState() => _ShareScreenPageState();
}

class _ShareScreenPageState extends State<ShareScreenPage> {
  MobileServiceAdapter get _service =>
      widget.service ?? MobileServiceAdapter.instance;

  Timer? _clientPoll;
  var _busy = false;
  List<ServicePermission> _permissions = const [];

  /// The core does not push the client list, so it is polled while this page
  /// is on screen and stopped as soon as it is not.
  static const _pollInterval = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _service.start();
    _service.addListener(_onServiceChanged);
    unawaited(_refresh());
    _clientPoll = Timer.periodic(
        _pollInterval, (_) => unawaited(_service.refreshClients()));
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _clientPoll?.cancel();
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  Future<void> _refresh() async {
    await _service.syncPermissions();
    await _service.refreshClients();
    final permissions = await _service.permissions();
    if (!mounted) return;
    setState(() => _permissions = permissions);
  }

  Future<void> _toggleService() async {
    setState(() => _busy = true);
    if (_service.isRunning) {
      await _service.stopService();
    } else {
      await _service.startService();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _ServiceCard(
              isRunning: _service.isRunning,
              isCapturing: _service.state.canCaptureScreen,
              busy: _busy,
              onToggle: _busy ? null : _toggleService),
          const SizedBox(height: 14),
          _IdentityCard(workspace: widget.workspace),
          if (_service.clients.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ClientsCard(
                clients: _service.clients,
                onRespond: (client, accept) =>
                    _service.respondToClient(client, accept),
                onDisconnect: _service.disconnectClient),
          ],
          if (_permissions.isNotEmpty) ...[
            const SizedBox(height: 14),
            _PermissionsCard(
                permissions: _permissions,
                onRequest: (permission) async {
                  await _service.requestPermission(permission);
                  await _refresh();
                }),
          ],
        ],
      );
}

/// Whether this device is being shared, and the control to change it.
class _ServiceCard extends StatelessWidget {
  const _ServiceCard(
      {required this.isRunning,
      required this.isCapturing,
      required this.busy,
      required this.onToggle});

  final bool isRunning;
  final bool isCapturing;
  final bool busy;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    // Running without the projection is its own state: the service is up but
    // nothing is being shared, and calling that "sharing" would be a lie.
    final (title, detail, icon) = switch ((isRunning, isCapturing)) {
      (false, _) => (
          'Not sharing',
          'Start sharing to let someone connect to this device.',
          LucideIcons.monitorOff
        ),
      (true, false) => (
          'Waiting for screen access',
          'Sharing is on, but Android has not granted screen capture yet.',
          LucideIcons.triangleAlert
        ),
      (true, true) => (
          'Sharing this screen',
          'Someone with your ID and password can connect.',
          LucideIcons.monitorCheck
        ),
    };

    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 22),
          const SizedBox(width: 11),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(detail,
                    style: TextStyle(fontSize: 12, color: _muted(context))),
              ])),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: CupertinoButton.filled(
            padding: const EdgeInsets.symmetric(vertical: 12),
            borderRadius: BorderRadius.circular(10),
            onPressed: onToggle,
            child: Text(
                busy
                    ? 'Working…'
                    : isRunning
                        ? 'Stop sharing'
                        : 'Start sharing',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}

/// The device id and password someone needs to connect here.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.workspace});

  final WorkspaceViewModel workspace;

  @override
  Widget build(BuildContext context) {
    final identity = workspace.identity;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('This device',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _CopyRow(
            label: 'RustDesk ID',
            // The real id, or an honest placeholder while the core starts.
            value: identity.isLoading
                ? 'Generating…'
                : identity.deviceId.isEmpty
                    ? 'Unavailable'
                    : identity.formattedDeviceId,
            canCopy: identity.deviceId.isNotEmpty,
            copyValue: identity.deviceId),
        const SizedBox(height: 10),
        _CopyRow(
            label: 'One-time password',
            value: identity.temporaryPassword.isEmpty
                ? 'Not set'
                : identity.temporaryPassword,
            canCopy: identity.temporaryPassword.isNotEmpty,
            copyValue: identity.temporaryPassword),
      ]),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow(
      {required this.label,
      required this.value,
      required this.canCopy,
      required this.copyValue});

  final String label;
  final String value;
  final bool canCopy;
  final String copyValue;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(label,
                  style: TextStyle(fontSize: 11, color: _muted(context))),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w700)),
            ])),
        if (canCopy)
          HoverTap(
            radius: 8,
            onTap: () => Clipboard.setData(ClipboardData(text: copyValue)),
            child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(LucideIcons.copy, size: 16)),
          ),
      ]);
}

/// Who is connected, and what can be done about them.
class _ClientsCard extends StatelessWidget {
  const _ClientsCard(
      {required this.clients,
      required this.onRespond,
      required this.onDisconnect});

  final List<ConnectedClient> clients;
  final void Function(ConnectedClient, bool accept) onRespond;
  final void Function(ConnectedClient) onDisconnect;

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Connections',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          for (final client in clients) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(client.displayName,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                        client.authorized
                            ? client.toolLabel
                            : '${client.toolLabel} · waiting for you',
                        style:
                            TextStyle(fontSize: 11, color: _muted(context))),
                  ])),
              // An unauthorised connection is a decision to make, not a
              // session to end.
              if (!client.authorized) ...[
                _SmallButton(
                    label: 'Refuse',
                    onTap: () => onRespond(client, false),
                    destructive: true),
                const SizedBox(width: 7),
                _SmallButton(
                    label: 'Accept', onTap: () => onRespond(client, true)),
              ] else
                _SmallButton(
                    label: 'Disconnect',
                    onTap: () => onDisconnect(client),
                    destructive: true),
            ]),
          ],
        ]),
      );
}

/// The Android permissions sharing wants, and what is missing.
class _PermissionsCard extends StatelessWidget {
  const _PermissionsCard(
      {required this.permissions, required this.onRequest});

  final List<ServicePermission> permissions;
  final ValueChanged<String> onRequest;

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Permissions',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          for (final permission in permissions) ...[
            const SizedBox(height: 12),
            Row(children: [
              Icon(
                  permission.granted
                      ? LucideIcons.circleCheck
                      : LucideIcons.circleAlert,
                  size: 16,
                  color: permission.granted
                      ? const Color(0xFF6E8C4A)
                      : _muted(context)),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_labelOf(permission.permission),
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                        permission.granted
                            ? 'Granted'
                            : permission.required
                                ? 'Required for sharing'
                                : _costOf(permission.permission),
                        style:
                            TextStyle(fontSize: 11, color: _muted(context))),
                  ])),
              if (!permission.granted)
                _SmallButton(
                    label: 'Allow',
                    onTap: () => onRequest(permission.permission)),
            ]),
          ],
        ]),
      );

  static String _labelOf(String permission) => switch (permission) {
        kAndroid13Notification => 'Notifications',
        kSystemAlertWindow => 'Floating window',
        kRecordAudio => 'Microphone',
        kManageExternalStorage => 'Files',
        _ => permission,
      };

  /// What is lost without an optional permission, so refusing one is an
  /// informed choice rather than a mystery.
  static String _costOf(String permission) => switch (permission) {
        kSystemAlertWindow => 'Without it there is no floating controller',
        kRecordAudio => 'Without it this device shares no sound',
        kManageExternalStorage => 'Without it files cannot be transferred',
        _ => 'Not granted',
      };
}

class _SmallButton extends StatelessWidget {
  const _SmallButton(
      {required this.label, required this.onTap, this.destructive = false});

  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
              color: destructive
                  ? CupertinoColors.transparent
                  : CupertinoTheme.of(context).primaryColor,
              border: destructive
                  ? Border.all(
                      color: const Color(0xFFD9B8A8).withValues(alpha: .7))
                  : null,
              borderRadius: BorderRadius.circular(8)),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: destructive
                      ? CupertinoColors.systemRed
                      : CupertinoColors.white)),
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
            color: CupertinoTheme.of(context).brightness == Brightness.dark
                ? const Color(0x1AFFFFFF)
                : const Color(0xD1FFFFFF),
            border: Border.all(
                color: const Color(0xFFD9B8A8).withValues(alpha: .55)),
            borderRadius: BorderRadius.circular(14)),
        child: child,
      );
}

Color _muted(BuildContext context) =>
    CupertinoTheme.of(context).brightness == Brightness.dark
        ? const Color(0xFFB9A69E)
        : const Color(0xFF7A5A4C);

/// Whether this build shows the sharing page at all.
bool get showsShareScreenPage => isMobile;
