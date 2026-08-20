import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:flutter_hbb/features/common/anchored_menu.dart';
import 'package:flutter_hbb/features/workspace/settings_view_model.dart';
import 'package:flutter_hbb/features/workspace/scan_config_page.dart';
import 'package:flutter_hbb/features/workspace/share_screen_page.dart';
import 'package:flutter_hbb/features/common/aurora_surface.dart';
import 'package:flutter_hbb/features/session/session_page.dart';
import 'package:flutter_hbb/features/workspace/workspace_view_model.dart';
import 'package:flutter_hbb/features/workspace/managed_status_card.dart';
import 'package:flutter_hbb/integration/adapters/connect_adapter.dart';
import 'package:flutter_hbb/integration/adapters/mobile_service_adapter.dart';
import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/adapters/peers_adapter.dart';
import 'package:flutter_hbb/integration/adapters/service_status_adapter.dart';
import 'package:flutter_hbb/integration/bridge/app_bootstrap.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/platform/platform_features.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/route_coordinator.dart';
import 'package:window_manager/window_manager.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.brightness,
    required this.onBrightnessChanged,
    this.viewModel,
    this.settings,
    this.initialSettingsTab,
    this.mobileService,
    this.showsSharing,
  });

  final Brightness brightness;
  final ValueChanged<Brightness> onBrightnessChanged;

  /// Injectable for tests. Defaults to a model over the live adapters.
  final WorkspaceViewModel? viewModel;

  /// Injectable settings model for tests.
  final SettingsViewModel? settings;

  /// Open straight to a settings page.
  ///
  /// The equivalent of the legacy `DesktopSettingPage.switch2page`: something
  /// elsewhere in the app (a "change this" link, a deep link) points at one
  /// settings category rather than the workspace.
  final SettingsTab? initialSettingsTab;

  /// Injectable sharing adapter for tests.
  final MobileServiceAdapter? mobileService;

  /// Whether to offer the sharing page. Defaults to mobile only; a test
  /// overrides it because the host running the test is not a phone.
  final bool? showsSharing;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  final _remoteId = TextEditingController();
  final _search = TextEditingController();
  late final WorkspaceViewModel _model;
  late final bool _ownsModel;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _ownsModel = widget.viewModel == null;
    _model = widget.viewModel ?? WorkspaceViewModel();
    // A deep link opens settings directly instead of the workspace.
    if (widget.initialSettingsTab != null) _page = _settingsPage;
    _model.addListener(_onModelChanged);
    AppBootstrap.instance.addListener(_onBootstrapChanged);
    _model.start();
    // Requests received during bootstrap are queued until the workspace is
    // mounted, so attach after the model is ready to open them.
    unawaited(RouteCoordinator.instance.attach(
      onConnectionRequest: _openRequest,
      onShowMainWindow: _showMainWindow,
    ));
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  void _onBootstrapChanged() {
    if (mounted) setState(() {});
  }

  /// The page index for a settings deep link. Settings is page 2.
  static const _settingsPage = 2;

  /// Sharing sits after settings so a settings deep link keeps its index on
  /// every platform, whether or not the sharing page exists.
  static const _sharePage = 3;

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    AppBootstrap.instance.removeListener(_onBootstrapChanged);
    RouteCoordinator.instance.detach();
    if (_ownsModel) _model.dispose();
    _remoteId.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            _openCommandPalette(),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _openCommandPalette(),
      },
      child: Focus(
        autofocus: true,
        child: CupertinoPageScaffold(
          child: _AuroraBackground(
            child: SafeArea(
              child: wide
                  ? Row(children: [
                      _Sidebar(
                          page: _page,
                          onChanged: _setPage,
                          showsSharing: _showsSharing),
                      Expanded(child: _content()),
                    ])
                  : Column(children: [
                      Expanded(child: _content()),
                      _CompactNavigation(
                          page: _page,
                          onChanged: _setPage,
                          showsSharing: _showsSharing),
                    ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() => Padding(
        padding: const EdgeInsets.fromLTRB(26, 22, 26, 12),
        child: Column(children: [
          _Header(
              title: [
                _greeting(),
                'Your devices',
                'Workspace settings',
                'Share this screen'
              ][_page],
              onCommand: _openCommandPalette,
              onNotifications: _showNotifications),
          const SizedBox(height: 22),
          Expanded(
            child: switch (_page) {
              0 => _Overview(
                  model: _model,
                  remoteId: _remoteId,
                  onOpenSession: _openSession,
                  onQuickConnect: _connectInMode,
                  onViewDevices: () => _setPage(1),
                ),
              1 => _Devices(
                  model: _model,
                  search: _search,
                  onOpenSession: _openSession,
                ),
              // Sharing this device's own screen is a phone and tablet
              // surface; a desktop shares through the service instead.
              _sharePage => ShareScreenPage(
                  workspace: _model,
                  service: widget.mobileService,
                ),
              _ => _Settings(
                  model: _model,
                  settings: widget.settings,
                  initialTab: widget.initialSettingsTab,
                  brightness: widget.brightness,
                  onBrightnessChanged: widget.onBrightnessChanged,
                ),
            },
          ),
        ]),
      );

  /// The signed-in account's name personalizes the greeting; signed out it
  /// stays generic rather than inventing a name.
  String _greeting() {
    final name = _model.accountName.trim();
    return name.isEmpty ? 'Welcome back' : 'Welcome back, $name';
  }

  bool get _showsSharing =>
      widget.showsSharing ?? PlatformFeatures.sharesOwnScreen;

  void _setPage(int page) => setState(() => _page = page);

  /// Connect through the existing FFI path, then show the session surface.
  Future<void> _openSession(String id) =>
      _connectInMode(id, ConnectionKind.remoteDesktop);

  Future<void> _connectInMode(String id, ConnectionKind kind) =>
      _openRequest(ConnectionRequest(peerId: id, kind: kind));

  Future<void> _openRequest(ConnectionRequest request) async {
    final result = await _model.connect(
      request.peerId,
      kind: request.kind,
      password: request.password,
      isSharedPassword: request.isSharedPassword,
      switchUuid: request.switchUuid,
      forceRelay: request.forceRelay,
      connToken: request.connToken,
    );
    if (!mounted) return;
    if (!result.isSuccess) {
      await _showConnectFailure(result);
      return;
    }
    // On desktop the session opens in its own window; there is nothing to
    // push. Mobile renders the session in-app.
    if (result.windowId != null) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => SessionPage(
          remoteId: result.peerId,
          password: request.password,
          kind: request.kind,
          forceRelay: request.forceRelay,
          isSharedPassword: request.isSharedPassword,
          connToken: request.connToken,
          switchUuid: request.switchUuid,
          initialMode: switch (request.kind) {
            ConnectionKind.fileTransfer => 1,
            ConnectionKind.terminal => 2,
            ConnectionKind.portForward || ConnectionKind.rdp => 3,
            ConnectionKind.remoteDesktop || ConnectionKind.viewCamera => 0,
          },
        ),
      ),
    );
  }

  Future<void> _showMainWindow() async {
    if (!isDesktop) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _showConnectFailure(ConnectResult result) =>
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Could not connect'),
          content: Text(switch (result.failure!) {
            ConnectFailure.emptyId => 'Enter a device ID to connect.',
            ConnectFailure.bridgeNotReady =>
              'RustDesk is still starting. Try again in a moment.',
            ConnectFailure.failed =>
              'The connection to ${result.peerId} failed.'
                  '${result.error == null ? '' : '\n\n${result.error}'}',
          }),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  void _openCommandPalette() => showCupertinoDialog<void>(
        context: context,
        builder: (context) =>
            _CommandDialog(model: _model, onConnect: _openSession),
      );

  void _showNotifications() => showCupertinoDialog<void>(
        context: context,
        builder: (context) => _NotificationDialog(
          model: _model,
          updateUrl: AppBootstrap.instance.softwareUpdateUrl,
        ),
      );
}

class _AuroraBackground extends StatelessWidget {
  const _AuroraBackground({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final base = dark ? const Color(0xFF181210) : const Color(0xFFFFF9F5);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base,
            dark ? const Color(0xFF291A17) : const Color(0xFFFFEEE5),
            base
          ],
        ),
      ),
      child: Stack(children: [
        const Positioned(
            top: -190, right: -120, child: _Glow(color: Color(0x44E87A51))),
        const Positioned(
            bottom: -250, left: -170, child: _Glow(color: Color(0x339E6F55))),
        Positioned.fill(child: child),
      ]),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: 480,
          height: 480,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(color: color, blurRadius: 105, spreadRadius: 22)
              ]),
        ),
      );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(
      {required this.page,
      required this.onChanged,
      required this.showsSharing});
  final int page;
  final ValueChanged<int> onChanged;
  final bool showsSharing;

  @override
  Widget build(BuildContext context) => Container(
        width: 232,
        margin: const EdgeInsets.fromLTRB(18, 18, 0, 18),
        padding: const EdgeInsets.all(10),
        decoration: panelDecoration(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 10, 10, 28),
            child: Row(children: [
              _Mark(),
              SizedBox(width: 10),
              Text('AURORA',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
            ]),
          ),
          _NavItem(
              icon: LucideIcons.layoutDashboard,
              label: 'Overview',
              selected: page == 0,
              onTap: () => onChanged(0)),
          _NavItem(
              icon: LucideIcons.panelsTopLeft,
              label: 'Devices',
              selected: page == 1,
              onTap: () => onChanged(1)),
          if (showsSharing)
            _NavItem(
                icon: LucideIcons.monitorSmartphone,
                label: 'Share',
                selected: page == 3,
                onTap: () => onChanged(3)),
          _NavItem(
              icon: LucideIcons.slidersHorizontal,
              label: 'Settings',
              selected: page == 2,
              onTap: () => onChanged(2)),
          const Spacer(),
          const _PrivacyNote(),
        ]),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = CupertinoTheme.of(context).primaryColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: HoverTap(
        radius: 10,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: .13) : null,
              borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(icon, size: 17, color: selected ? accent : null),
            const SizedBox(width: 10),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? accent : null)),
          ]),
        ),
      ),
    );
  }
}

class _CompactNavigation extends StatelessWidget {
  const _CompactNavigation(
      {required this.page,
      required this.onChanged,
      required this.showsSharing});
  final int page;
  final ValueChanged<int> onChanged;
  final bool showsSharing;

  @override
  Widget build(BuildContext context) {
    // The page index is the second element, not the position: sharing sits at
    // index 3 so a settings deep link keeps index 2 everywhere.
    final items = <(IconData, String, int)>[
      (LucideIcons.layoutDashboard, 'Home', 0),
      (LucideIcons.panelsTopLeft, 'Devices', 1),
      if (showsSharing) (LucideIcons.monitorSmartphone, 'Share', 3),
      (LucideIcons.slidersHorizontal, 'Settings', 2),
    ];
    final accent = CupertinoTheme.of(context).primaryColor;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(4),
      decoration: panelDecoration(context),
      child: Row(children: [
        for (final (icon, label, target) in items)
          Expanded(
            child: HoverTap(
              radius: 8,
              onTap: () => onChanged(target),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                    color:
                        page == target ? accent.withValues(alpha: .13) : null,
                    borderRadius: BorderRadius.circular(8)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 16, color: page == target ? accent : null),
                  const SizedBox(height: 3),
                  Text(label,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: page == target
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: page == target ? accent : null)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.onCommand,
    required this.onNotifications,
  });
  final String title;
  final VoidCallback onCommand;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    return Row(children: [
      Expanded(
          child: Text(title,
              style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.6))),
      _CompactButton(
          icon: LucideIcons.search,
          label: compact ? null : 'Command',
          onTap: onCommand),
      const SizedBox(width: 8),
      _CompactButton(icon: LucideIcons.bell, onTap: onNotifications),
      const SizedBox(width: 8),
      const _Avatar(),
    ]);
  }
}

class _Overview extends StatelessWidget {
  const _Overview(
      {required this.model,
      required this.remoteId,
      required this.onOpenSession,
      required this.onQuickConnect,
      required this.onViewDevices});
  final WorkspaceViewModel model;
  final TextEditingController remoteId;
  final ValueChanged<String> onOpenSession;
  final void Function(String, ConnectionKind) onQuickConnect;
  final VoidCallback onViewDevices;

  @override
  Widget build(BuildContext context) {
    if (!model.isBridgeReady) {
      return _BridgeError(error: model.bridgeError);
    }
    return ListView(padding: const EdgeInsets.only(right: 14), children: [
      LayoutBuilder(builder: (context, constraints) {
        final stacked = constraints.maxWidth < 720;
        final connect =
            _QuickConnect(controller: remoteId, onConnect: onQuickConnect);
        final identity = _IdentityCard(identity: model.identity);
        return stacked
            ? Column(children: [
                connect,
                const SizedBox(height: 14),
                identity,
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 6, child: connect),
                const SizedBox(width: 14),
                Expanded(flex: 4, child: identity),
              ]);
      }),
      const SizedBox(height: 24),
      _SectionTitle(
          title: 'Recent devices', action: 'View all', onAction: onViewDevices),
      const SizedBox(height: 10),
      _DeviceGrid(
        peers: model.peersOf(PeerScope.recent),
        state: model.loadStateOf(PeerScope.recent),
        onOpenSession: onOpenSession,
        limit: 3,
      ),
      const SizedBox(height: 24),
      const _SectionTitle(title: 'Managed access'),
      const SizedBox(height: 10),
      const ManagedStatusCard(),
      const SizedBox(height: 24),
      const _SectionTitle(title: 'Workspace pulse'),
      const SizedBox(height: 10),
      _Pulse(model: model),
      const SizedBox(height: 24),
      const _SectionTitle(title: 'Service health'),
      const SizedBox(height: 10),
      _ServiceHealth(model: model),
    ]);
  }
}

class _ServiceHealth extends StatelessWidget {
  const _ServiceHealth({required this.model});
  final WorkspaceViewModel model;

  @override
  Widget build(BuildContext context) {
    final identity = model.identity;
    return _Panel(
      padding: const EdgeInsets.all(14),
      child: Wrap(spacing: 26, runSpacing: 14, children: [
        _HealthMetric(
          icon: LucideIcons.wifi,
          label: 'Network',
          value: switch (model.connectStatus) {
            ConnectStatus.connected => 'Connected',
            ConnectStatus.connecting => 'Connecting',
            ConnectStatus.disconnected => 'Offline',
            ConnectStatus.unknown =>
              identity.isLoading ? 'Checking' : 'Unknown',
          },
        ),
        _HealthMetric(
          icon: LucideIcons.route,
          label: 'Relay',
          value: model.isForceRelay ? 'Always on' : 'Direct first',
        ),
        _HealthMetric(
          icon: LucideIcons.shieldCheck,
          label: 'Service',
          value: identity.isServiceRunning ? 'Accepting' : 'Stopped',
        ),
      ]),
    );
  }
}

/// Shown when the native core could not be loaded. The workspace has no data
/// to render in that state, so it says so rather than looking empty.
class _BridgeError extends StatelessWidget {
  const _BridgeError({required this.error});
  final Object? error;

  @override
  Widget build(BuildContext context) => Center(
        child: _Panel(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(LucideIcons.triangleAlert, size: 30),
            const SizedBox(height: 12),
            const Text('RustDesk core unavailable',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 6),
            Text(
              'The application could not start its native service, so no '
              'devices or settings can be shown.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: _muted(context)),
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text('$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: _muted(context))),
            ],
          ]),
        ),
      );
}

class _HealthMetric extends StatelessWidget {
  const _HealthMetric(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 156,
        child: Row(children: [
          Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: const Color(0xFFB55433).withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 16, color: const Color(0xFF9E482E))),
          const SizedBox(width: 9),
          // Values are model-driven and vary in length, so the text column
          // takes the remaining width and ellipsizes rather than overflowing.
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(label, style: const TextStyle(fontSize: 11)),
                const SizedBox(height: 2),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ]))
        ]),
      );
}

class _QuickConnect extends StatefulWidget {
  const _QuickConnect({required this.controller, required this.onConnect});
  final TextEditingController controller;
  final void Function(String, ConnectionKind) onConnect;

  @override
  State<_QuickConnect> createState() => _QuickConnectState();
}

class _QuickConnectState extends State<_QuickConnect> {
  var _mode = 0;

  /// The connection kinds Quick Connect offers, in picker order.
  static const _kinds = [
    ConnectionKind.remoteDesktop,
    ConnectionKind.fileTransfer,
    ConnectionKind.terminal,
  ];

  /// Connect to whatever the field holds. An empty field does nothing: there
  /// is no default device to fall back to.
  void _submit([String? value]) {
    final id = (value ?? widget.controller.text).trim();
    if (id.isEmpty) return;
    widget.onConnect(id, _kinds[_mode]);
  }

  @override
  Widget build(BuildContext context) {
    final accent = CupertinoTheme.of(context).primaryColor;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFFA64B30), Color(0xFF6F3328)]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: accent.withValues(alpha: .18),
              blurRadius: 28,
              offset: const Offset(0, 12))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('QUICK CONNECT',
            style: TextStyle(
                color: Color(0xFFFFDCCF),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2)),
        const SizedBox(height: 18),
        const Text('Connect in a moment',
            style: TextStyle(
                color: CupertinoColors.white,
                fontSize: 23,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        const Text('Start a secure session with a device ID.',
            style: TextStyle(color: Color(0xFFFFDED1), fontSize: 13)),
        const SizedBox(height: 18),
        CupertinoTextField(
          controller: widget.controller,
          onSubmitted: _submit,
          keyboardType: TextInputType.text,
          placeholder: 'Remote ID',
          placeholderStyle: const TextStyle(color: Color(0xFFEFC5B7)),
          prefix: const Padding(
              padding: EdgeInsets.only(left: 11),
              child:
                  Icon(LucideIcons.hash, size: 16, color: Color(0xFFFFDDCF))),
          style: const TextStyle(
              color: CupertinoColors.white, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: BoxDecoration(
              color: CupertinoColors.white.withValues(alpha: .12),
              border: Border.all(
                  color: CupertinoColors.white.withValues(alpha: .23)),
              borderRadius: BorderRadius.circular(10)),
        ),
        const SizedBox(height: 12),
        _QuickModePicker(
            mode: _mode, onChanged: (mode) => setState(() => _mode = mode)),
        const SizedBox(height: 12),
        Align(
            alignment: Alignment.centerRight,
            child: _LightButton(
                label: 'Connect',
                icon: LucideIcons.arrowRight,
                onTap: _submit)),
      ]),
    );
  }
}

class _QuickModePicker extends StatelessWidget {
  const _QuickModePicker({required this.mode, required this.onChanged});
  final int mode;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (final option in [
          (LucideIcons.monitor, 'Desktop'),
          (LucideIcons.folder, 'Files'),
          (LucideIcons.terminal, 'Terminal')
        ])
          Expanded(
              child: Padding(
            padding: EdgeInsets.only(right: option.$2 == 'Terminal' ? 0 : 6),
            child: GestureDetector(
              onTap: () => onChanged([
                (LucideIcons.monitor, 'Desktop'),
                (LucideIcons.folder, 'Files'),
                (LucideIcons.terminal, 'Terminal')
              ].indexOf(option)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: mode ==
                          [
                            (LucideIcons.monitor, 'Desktop'),
                            (LucideIcons.folder, 'Files'),
                            (LucideIcons.terminal, 'Terminal')
                          ].indexOf(option)
                      ? CupertinoColors.white.withValues(alpha: .22)
                      : CupertinoColors.white.withValues(alpha: .08),
                  border: Border.all(
                      color: CupertinoColors.white.withValues(alpha: .14)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(option.$1, size: 15, color: CupertinoColors.white),
                  const SizedBox(height: 4),
                  Text(option.$2,
                      style: const TextStyle(
                          color: CupertinoColors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          )),
      ]);
}

class _IdentityCard extends StatefulWidget {
  const _IdentityCard({required this.identity});
  final IdentityView identity;

  @override
  State<_IdentityCard> createState() => _IdentityCardState();
}

class _IdentityCardState extends State<_IdentityCard> {
  var _copied = false;

  @override
  Widget build(BuildContext context) {
    final identity = widget.identity;
    final hasId = identity.deviceId.isNotEmpty;
    return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(LucideIcons.shieldCheck, size: 19),
        const Spacer(),
        _OnlinePill(online: identity.isOnline),
      ]),
      const SizedBox(height: 34),
      const Text('This device',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 5),
      Text(
        _subtitle(identity),
        style: TextStyle(fontSize: 12, color: _muted(context)),
      ),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(
          child: Text(
            identity.isLoading
                ? 'Generating…'
                : hasId
                    ? identity.formattedDeviceId
                    : 'Unavailable',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: hasId ? null : _muted(context),
            ),
          ),
        ),
        if (hasId)
          _CompactButton(
              icon: _copied ? LucideIcons.check : LucideIcons.copy,
              onTap: _copyId),
      ]),
      AnimatedSize(
          duration: const Duration(milliseconds: 160),
          child: _copied
              ? const Padding(
                  padding: EdgeInsets.only(top: 7),
                  child: Text('Device ID copied',
                      style: TextStyle(color: Color(0xFF9E482E), fontSize: 11)))
              : const SizedBox.shrink()),
    ]));
  }

  String _subtitle(IdentityView identity) {
    if (identity.hasError) return 'Could not read the service status';
    if (identity.isLoading) return 'Starting the service…';
    if (!identity.isServiceRunning) {
      return 'Sharing is stopped — incoming connections are refused';
    }
    return identity.isOnline
        ? 'Online and ready for secure access'
        : 'Offline — not registered with the server';
  }

  Future<void> _copyId() async {
    // Copy the unformatted id: spaces are display-only.
    await Clipboard.setData(ClipboardData(text: widget.identity.deviceId));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }
}

class _Devices extends StatelessWidget {
  const _Devices({
    required this.model,
    required this.search,
    required this.onOpenSession,
  });
  final WorkspaceViewModel model;
  final TextEditingController search;
  final ValueChanged<String> onOpenSession;

  @override
  Widget build(BuildContext context) {
    if (!model.isBridgeReady) {
      return _BridgeError(error: model.bridgeError);
    }
    return ListView(padding: const EdgeInsets.only(right: 14), children: [
      CupertinoTextField(
          controller: search,
          onChanged: model.setQuery,
          prefix: const Padding(
              padding: EdgeInsets.only(left: 11),
              child: Icon(LucideIcons.search, size: 16)),
          placeholder: 'Search devices, people, or tags',
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: _inputDecoration(context)),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
            child: Text(model.scope.label,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700))),
        _SortMenu(
            sortType: model.sortType,
            onChanged: (type) => model.setSortType(type)),
        const SizedBox(width: 8),
        _TogglePill(
            label: 'Online',
            enabled: model.onlyOnline,
            onTap: () => model.setOnlyOnline(!model.onlyOnline)),
      ]),
      const SizedBox(height: 10),
      _DeviceScopePicker(
          scopes: model.availableScopes,
          scope: model.scope,
          onChanged: model.setScope),
      const SizedBox(height: 12),
      _DeviceGrid(
        peers: model.visiblePeers,
        state: model.loadState,
        error: model.scopeError,
        isFiltered: model.query.isNotEmpty || model.onlyOnline,
        onOpenSession: onOpenSession,
        onToggleFavorite: model.toggleFavorite,
        onRemove: model.removePeer,
        onSetAlias: model.setAlias,
        onForgetPassword: model.forgetPassword,
        isFavorite: model.isFavorite,
      ),
    ]);
  }
}

class _DeviceScopePicker extends StatelessWidget {
  const _DeviceScopePicker(
      {required this.scopes, required this.scope, required this.onChanged});
  final List<PeerScope> scopes;
  final PeerScope scope;
  final ValueChanged<PeerScope> onChanged;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
              color: CupertinoTheme.of(context)
                  .primaryColor
                  .withValues(alpha: .08),
              borderRadius: BorderRadius.circular(9)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final option in scopes)
              GestureDetector(
                  onTap: () => onChanged(option),
                  child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                          color: scope == option
                              ? CupertinoColors.white.withValues(alpha: .9)
                              : null,
                          borderRadius: BorderRadius.circular(7)),
                      child: Text(option.label,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: scope == option
                                  ? FontWeight.w700
                                  : FontWeight.w500))))
          ])));
}

/// Sort control over the existing `peer-sorting` option values.
class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sortType, required this.onChanged});
  final String sortType;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => AnchoredMenu(
        width: 186,
        actions: [
          for (final type in PeerSortType.values)
            MenuAction(
              label: type,
              isSelected: type == sortType,
              onTap: () => onChanged(type),
            ),
        ],
        builder: (context, open) => MenuTrigger(
            radius: 9,
            open: open,
            child: const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(LucideIcons.arrowUpDown, size: 15))),
      );
}

class _Settings extends StatefulWidget {
  const _Settings(
      {required this.model,
      required this.brightness,
      required this.onBrightnessChanged,
      this.settings,
      this.initialTab});
  final WorkspaceViewModel model;

  /// Injectable for tests; defaults to a model over the live options.
  final SettingsViewModel? settings;

  /// The category to open, from a settings deep link.
  final SettingsTab? initialTab;
  final Brightness brightness;
  final ValueChanged<Brightness> onBrightnessChanged;

  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  final _search = TextEditingController();
  late final SettingsViewModel _settings;
  late final bool _ownsSettings;

  @override
  void initState() {
    super.initState();
    _ownsSettings = widget.settings == null;
    _settings = widget.settings ?? SettingsViewModel();
    _settings.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  static const _categories = [
    'All',
    'This device',
    'Access',
    'Workspace',
    'Display',
    'Input',
    'File transfer',
    'Network',
    'Updates & support'
  ];
  bool unattended = false;
  bool automaticUpdates = true;
  bool clipboardSync = true;
  bool confirmOverwrite = true;
  bool showHiddenFiles = false;
  String language = 'English';
  String relayServer = 'Automatic';
  String keyboardMode = 'Map shortcuts';
  String scrollDirection = 'Natural';
  late String category = _categoryFor(widget.initialTab);

  /// The Aurora category that holds a legacy settings tab.
  ///
  /// Aurora groups settings differently from the legacy tabbed page, so a
  /// deep link lands on the category that contains what it asked for rather
  /// than a page that no longer exists.
  static String _categoryFor(SettingsTab? tab) {
    switch (tab) {
      case SettingsTab.safety:
        return 'Access';
      case SettingsTab.network:
        return 'Network';
      case SettingsTab.display:
        return 'Display';
      case SettingsTab.about:
        return 'Updates & support';
      case SettingsTab.plugin:
        return 'Workspace';
      case SettingsTab.printer:
        return 'File transfer';
      case SettingsTab.general:
      case SettingsTab.account:
      case null:
        return 'All';
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    if (_ownsSettings) _settings.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final panels = <Widget?>[
      _panel('This device', [
        (
          'device rustdesk id',
          _SettingRow(
              icon: LucideIcons.monitor,
              title: 'This device',
              // The real id, or an honest placeholder while it loads.
              subtitle: widget.model.identity.isLoading
                  ? 'Reading the RustDesk ID…'
                  : widget.model.identity.deviceId.isEmpty
                      ? 'RustDesk ID unavailable'
                      : 'RustDesk ID '
                          '${widget.model.identity.formattedDeviceId}')
        ),
        (
          'storage recordings files',
          _SettingRow(
              icon: LucideIcons.hardDrive,
              title: 'Storage',
              subtitle: 'Session recordings and received files',
              onTap: () => _openSubpage(_SettingsSubpageKind.storage))
        ),
      ]),
      // Everything here governs what someone connecting *to* this device may
      // do. A build that cannot be controlled has nothing to permit, so the
      // panel is absent rather than showing switches that do nothing.
      if (_settings.hasIncomingPermissions)
        _panel('Access', [
          // What people who connect are allowed to do. Backed by the same
          // permission keys the legacy Security page wrote.
          (
            'permissions keyboard clipboard audio file terminal restart',
            _SettingToggleGroup(
                model: _settings,
                toggles: SettingsViewModel.securityToggles,
                icon: LucideIcons.badgeCheck)
          ),
          (
            'two-factor 2fa authenticator trusted devices telegram',
            _SettingRow(
                icon: LucideIcons.shieldCheck,
                title: 'Two-factor authentication',
                subtitle: _settings.isTwoFactorEnabled
                    ? 'On. Manage trusted devices and codes.'
                    : 'Ask for a code from an authenticator app',
                onTap: () => _openSubpage(_SettingsSubpageKind.twoFactor))
          ),
          (
            'password unattended',
            _SettingRow(
                icon: LucideIcons.keyRound,
                title: 'Access password',
                subtitle: _settings.isPasswordChangeDisabled
                    ? 'Managed by your deployment'
                    : 'Set a password for unattended access',
                onTap: () => _openSubpage(_SettingsSubpageKind.password))
          ),
        ]),
      _panel('Workspace', [
        (
          'appearance light dark theme',
          _AppearancePicker(
              brightness: widget.brightness,
              onChanged: widget.onBrightnessChanged)
        ),
        (
          'tabs confirm closing updates recording',
          _SettingToggleGroup(
              model: _settings,
              toggles: SettingsViewModel.workspaceToggles,
              icon: LucideIcons.panelsTopLeft)
        ),
        (
          'plugins extensions add-ons',
          _SettingRow(
              icon: LucideIcons.blocks,
              title: 'Plugins',
              subtitle: _settings.isPluginFeatureEnabled
                  ? 'Install and manage RustDesk plugins'
                  : 'Not available in this build',
              onTap: _settings.isPluginFeatureEnabled
                  ? () => _openSubpage(_SettingsSubpageKind.plugins)
                  : null)
        ),
        (
          'language english vietnamese deutsch',
          _SettingSelect(
              icon: LucideIcons.languages,
              title: 'Language',
              subtitle: 'Choose the app language.',
              value: language,
              options: const ['English', 'Vietnamese', 'Deutsch'],
              onChanged: (value) => setState(() => language = value))
        ),
      ]),
      _panel('Display', [
        (
          'cursor quality codec hardware wallpaper capture',
          _SettingToggleGroup(
              model: _settings,
              toggles: SettingsViewModel.displayToggles,
              icon: LucideIcons.monitorCog)
        ),
        (
          'privacy screen remote control',
          _SettingRow(
              icon: LucideIcons.eye,
              title: 'Privacy screen',
              subtitle: 'Hide the local screen during remote control',
              onTap: () => _openSubpage(_SettingsSubpageKind.privacy))
        ),
      ]),
      _panel('Input', [
        (
          'keyboard shortcuts mapping',
          _SettingSelect(
              icon: LucideIcons.keyboard,
              title: 'Keyboard shortcuts',
              subtitle: 'Choose how local keys reach the remote device.',
              value: keyboardMode,
              options: const ['Map shortcuts', 'Send all keys', 'Local only'],
              onChanged: (value) => setState(() => keyboardMode = value))
        ),
        (
          'mouse scroll direction',
          _SettingSelect(
              icon: LucideIcons.mouse,
              title: 'Mouse scroll direction',
              subtitle: 'Match the local device or keep it natural.',
              value: scrollDirection,
              options: const ['Natural', 'Match remote', 'Reverse'],
              onChanged: (value) => setState(() => scrollDirection = value))
        ),
        (
          'clipboard sync copy paste',
          _SwitchRow(
              icon: LucideIcons.clipboard,
              title: 'Clipboard sync',
              subtitle: 'Share copied text with remote devices',
              value: clipboardSync,
              onChanged: (value) => setState(() => clipboardSync = value))
        ),
      ]),
      _panel('File transfer', [
        (
          'download folder received files',
          _SettingRow(
              icon: LucideIcons.folderOpen,
              title: 'Receive folder',
              subtitle: 'Downloads / RustDesk',
              onTap: () => _openSubpage(_SettingsSubpageKind.receiveFolder))
        ),
        (
          'overwrite existing files confirm',
          _SwitchRow(
              icon: LucideIcons.files,
              title: 'Confirm before overwrite',
              subtitle: 'Ask before replacing files with the same name',
              value: confirmOverwrite,
              onChanged: (value) => setState(() => confirmOverwrite = value))
        ),
        (
          'printer printing remote print jobs',
          _SettingRow(
              icon: LucideIcons.printer,
              title: 'Printing',
              subtitle: _settings.isPrinterSettingHidden
                  ? 'Managed by your deployment'
                  : 'Send and receive print jobs during a session',
              onTap: _settings.isPrinterSettingHidden
                  ? null
                  : () => _openSubpage(_SettingsSubpageKind.printer))
        ),
        (
          'hidden files transfer',
          _SwitchRow(
              icon: LucideIcons.fileDown,
              title: 'Show hidden files',
              subtitle: 'Include hidden files in remote file browser',
              value: showHiddenFiles,
              onChanged: (value) => setState(() => showHiddenFiles = value))
        ),
      ]),
      _panel('Network', [
        (
          'direct relay websocket udp discovery',
          _SettingToggleGroup(
              model: _settings,
              toggles: SettingsViewModel.networkToggles,
              icon: LucideIcons.network)
        ),
        (
          'id relay api server custom',
          _SettingRow(
              icon: LucideIcons.server,
              title: 'ID and relay server',
              subtitle: _settings.isServerSettingHidden
                  ? 'Managed by your deployment'
                  : 'Point this client at your own servers',
              onTap: _settings.isServerSettingHidden
                  ? null
                  : () => _openSubpage(_SettingsSubpageKind.relayServer))
        ),
        (
          'proxy socks5 http https',
          _SettingRow(
              icon: LucideIcons.shuffle,
              title: 'Proxy',
              subtitle: _settings.isProxySettingHidden
                  ? 'Managed by your deployment'
                  : 'Send connections through a SOCKS5 or HTTP proxy',
              onTap: _settings.isProxySettingHidden
                  ? null
                  : () => _openSubpage(_SettingsSubpageKind.proxy))
        ),
        (
          'network diagnostics connectivity',
          _SettingRow(
              icon: LucideIcons.globe2,
              title: 'Network diagnostics',
              subtitle: 'Check connectivity and server status',
              onTap: () => _openSubpage(_SettingsSubpageKind.diagnostics))
        ),
      ]),
      _panel('Updates & support', [
        (
          'updates automatic',
          _SwitchRow(
              icon: LucideIcons.refreshCw,
              title: 'Check for updates automatically',
              subtitle: 'Keep RustDesk ready for the latest improvements',
              value: automaticUpdates,
              onChanged: (value) => setState(() => automaticUpdates = value))
        ),
        (
          'about version support',
          _SettingRow(
              icon: LucideIcons.info,
              title: 'About RustDesk',
              // The real version lives on the subpage; naming one here would
              // be a second place to go stale.
              subtitle: 'Version, fingerprint and license',
              onTap: () => _openSubpage(_SettingsSubpageKind.about))
        ),
      ]),
    ].whereType<Widget>().toList();

    return ListView(padding: const EdgeInsets.only(right: 14), children: [
      CupertinoTextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          prefix: const Padding(
              padding: EdgeInsets.only(left: 11),
              child: Icon(LucideIcons.search, size: 16)),
          suffix: _search.text.isEmpty
              ? null
              : GestureDetector(
                  onTap: () {
                    _search.clear();
                    setState(() {});
                  },
                  child: const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: Icon(LucideIcons.x, size: 15))),
          placeholder: 'Search settings',
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: _inputDecoration(context)),
      const SizedBox(height: 10),
      _SettingsCategoryBar(
          categories: _categories,
          selected: category,
          onSelected: (value) => setState(() => category = value)),
      const SizedBox(height: 16),
      if (panels.isEmpty) const _SettingsEmptyState() else ..._withGaps(panels),
      const SizedBox(height: 24),
    ]);
  }

  Widget? _panel(String title, List<(String, Widget)> settings) {
    if (category != 'All' && category != title) return null;
    final query = _search.text.trim().toLowerCase();
    final rows = settings
        .where((setting) =>
            query.isEmpty ||
            '$title ${setting.$1}'.toLowerCase().contains(query))
        .map((setting) => setting.$2)
        .toList();
    if (rows.isEmpty) return null;
    return _Panel(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_PanelTitle(title), ...rows]));
  }

  void _openSubpage(_SettingsSubpageKind kind) =>
      Navigator.of(context).push(CupertinoPageRoute<void>(
          builder: (_) => _SettingsSubpage(kind: kind, settings: _settings)));
}

class _SettingsCategoryBar extends StatelessWidget {
  const _SettingsCategoryBar(
      {required this.categories,
      required this.selected,
      required this.onSelected});
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: categories
          .map((category) => HoverTap(
              radius: 8,
              onTap: () => onSelected(category),
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                  decoration: BoxDecoration(
                      color: category == selected
                          ? CupertinoTheme.of(context)
                              .primaryColor
                              .withValues(alpha: .14)
                          : CupertinoColors.transparent,
                      border: Border.all(
                          color: category == selected
                              ? CupertinoTheme.of(context)
                                  .primaryColor
                                  .withValues(alpha: .25)
                              : const Color(0xFFD9B8A8).withValues(alpha: .55)),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(category,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              category == selected ? FontWeight.w700 : FontWeight.w500)))))
          .toList());
}

List<Widget> _withGaps(List<Widget> children) => [
      for (var index = 0; index < children.length; index++) ...[
        children[index],
        if (index < children.length - 1) const SizedBox(height: 14),
      ]
    ];

class _SettingsEmptyState extends StatelessWidget {
  const _SettingsEmptyState();

  @override
  Widget build(BuildContext context) => _Panel(
      child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Column(children: [
            Icon(LucideIcons.searchX, size: 20),
            SizedBox(height: 9),
            Text('No settings found',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            SizedBox(height: 3),
            Text('Try another word or phrase.', style: TextStyle(fontSize: 11))
          ])));
}

enum _SettingsSubpageKind {
  storage,
  password,
  twoFactor,
  privacy,
  receiveFolder,
  printer,
  plugins,
  relayServer,
  proxy,
  diagnostics,
  about,
}

class _SettingsSubpage extends StatefulWidget {
  const _SettingsSubpage({required this.kind, required this.settings});
  final _SettingsSubpageKind kind;
  final SettingsViewModel settings;

  @override
  State<_SettingsSubpage> createState() => _SettingsSubpageState();
}

class _SettingsSubpageState extends State<_SettingsSubpage> {
  bool primarySwitch = true;
  bool secondarySwitch = false;
  bool diagnosticsChecked = false;

  ({IconData icon, String title, String subtitle}) get _header =>
      switch (widget.kind) {
        _SettingsSubpageKind.storage => (
            icon: LucideIcons.hardDrive,
            title: 'Storage',
            subtitle: 'Manage local recordings and received files.'
          ),
        _SettingsSubpageKind.password => (
            icon: LucideIcons.keyRound,
            title: 'Access password',
            subtitle: 'Protect unattended access to this device.'
          ),
        _SettingsSubpageKind.twoFactor => (
            icon: LucideIcons.shieldCheck,
            title: 'Two-factor authentication',
            subtitle: 'Require a code before anyone connects to this device.'
          ),
        _SettingsSubpageKind.privacy => (
            icon: LucideIcons.eye,
            title: 'Privacy screen',
            subtitle: 'Keep the local screen private during remote control.'
          ),
        _SettingsSubpageKind.receiveFolder => (
            icon: LucideIcons.folderOpen,
            title: 'Receive folder',
            subtitle: 'Choose where files from remote devices are saved.'
          ),
        _SettingsSubpageKind.printer => (
            icon: LucideIcons.printer,
            title: 'Printing',
            subtitle: 'Print to a remote device, and handle jobs sent here.'
          ),
        _SettingsSubpageKind.plugins => (
            icon: LucideIcons.blocks,
            title: 'Plugins',
            subtitle: 'Extend RustDesk with plugins from your sources.'
          ),
        _SettingsSubpageKind.relayServer => (
            icon: LucideIcons.server,
            title: 'Custom relay server',
            subtitle: 'Route remote sessions through your own relay.'
          ),
        _SettingsSubpageKind.proxy => (
            icon: LucideIcons.shuffle,
            title: 'Proxy',
            subtitle: 'Reach the ID and relay servers through a proxy.'
          ),
        _SettingsSubpageKind.diagnostics => (
            icon: LucideIcons.globe2,
            title: 'Network diagnostics',
            subtitle: 'Check the services used to establish a session.'
          ),
        _SettingsSubpageKind.about => (
            icon: LucideIcons.info,
            title: 'About RustDesk',
            subtitle: 'Version and workspace information.'
          ),
      };

  @override
  Widget build(BuildContext context) {
    final header = _header;
    return _AuroraBackground(
        child: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(children: [
                          Row(children: [
                            HoverTap(
                                radius: 8,
                                onTap: () => Navigator.pop(context),
                                child: const Padding(
                                    padding: EdgeInsets.all(7),
                                    child: Icon(LucideIcons.chevronLeft,
                                        size: 18))),
                            const SizedBox(width: 7),
                            const Text('Settings',
                                style: TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                          ]),
                          const SizedBox(height: 16),
                          Expanded(
                              child: ListView(children: [
                            _Panel(
                                child: Row(children: [
                              Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                      color: CupertinoTheme.of(context)
                                          .primaryColor
                                          .withValues(alpha: .12),
                                      borderRadius: BorderRadius.circular(10)),
                                  child: Icon(header.icon, size: 20)),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(header.title,
                                        style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 3),
                                    Text(header.subtitle,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: _muted(context)))
                                  ]))
                            ])),
                            const SizedBox(height: 14),
                            ..._withGaps(_sections()),
                            const SizedBox(height: 24),
                          ]))
                        ]))))));
  }

  List<Widget> _sections() => switch (widget.kind) {
        _SettingsSubpageKind.storage => [
            _Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const _PanelTitle('Local storage'),
                  const _SettingRow(
                      icon: LucideIcons.folderOpen,
                      title: 'Recording folder',
                      subtitle: 'Movies / RustDesk'),
                  _SwitchRow(
                      icon: LucideIcons.video,
                      title: 'Keep session recordings',
                      subtitle: 'Save recordings after a remote session ends',
                      value: primarySwitch,
                      onChanged: (value) =>
                          setState(() => primarySwitch = value)),
                  _SwitchRow(
                      icon: LucideIcons.trash2,
                      title: 'Clear temporary files',
                      subtitle: 'Remove cached previews after 30 days',
                      value: secondarySwitch,
                      onChanged: (value) =>
                          setState(() => secondarySwitch = value)),
                ])),
          ],
        _SettingsSubpageKind.password => [
            _PermanentPasswordPanel(settings: widget.settings),
          ],
        _SettingsSubpageKind.twoFactor => [
            _TwoFactorPanel(settings: widget.settings),
          ],
        _SettingsSubpageKind.privacy => [
            _Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const _PanelTitle('During remote control'),
                  _SwitchRow(
                      icon: LucideIcons.eyeOff,
                      title: 'Enable privacy screen',
                      subtitle:
                          'Dim the local display while someone is connected',
                      value: primarySwitch,
                      onChanged: (value) =>
                          setState(() => primarySwitch = value)),
                  _SwitchRow(
                      icon: LucideIcons.lock,
                      title: 'Block local input',
                      subtitle: 'Prevent local keyboard and mouse activity',
                      value: secondarySwitch,
                      onChanged: (value) =>
                          setState(() => secondarySwitch = value)),
                ])),
          ],
        _SettingsSubpageKind.receiveFolder => [
            _Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const _PanelTitle('File destination'),
                  const _SubpageField(
                      label: 'Default folder',
                      placeholder: 'Downloads / RustDesk'),
                  const SizedBox(height: 12),
                  _SwitchRow(
                      icon: LucideIcons.folderOpen,
                      title: 'Ask every time',
                      subtitle: 'Choose a destination before receiving files',
                      value: primarySwitch,
                      onChanged: (value) =>
                          setState(() => primarySwitch = value)),
                ])),
          ],
        _SettingsSubpageKind.printer => [
            _PrinterPanel(settings: widget.settings),
          ],
        _SettingsSubpageKind.plugins => [
            _PluginPanel(settings: widget.settings),
          ],
        _SettingsSubpageKind.relayServer => [
            _ServerConfigPanel(settings: widget.settings),
          ],
        _SettingsSubpageKind.proxy => [
            _ProxyPanel(settings: widget.settings),
          ],
        _SettingsSubpageKind.diagnostics => [
            _Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const _PanelTitle('Connection services'),
                  _DiagnosticsRow(
                      label: 'Rendezvous service',
                      value:
                          diagnosticsChecked ? 'Reachable' : 'Ready to check'),
                  _DiagnosticsRow(
                      label: 'Relay service',
                      value:
                          diagnosticsChecked ? 'Available' : 'Ready to check'),
                  _DiagnosticsRow(
                      label: 'Direct connection',
                      value:
                          diagnosticsChecked ? 'Available' : 'Ready to check'),
                  const SizedBox(height: 8),
                  _SubpageButton(
                      label: diagnosticsChecked
                          ? 'Checked just now'
                          : 'Run checks',
                      icon: LucideIcons.refreshCw,
                      onTap: () => setState(() => diagnosticsChecked = true)),
                ])),
          ],
        _SettingsSubpageKind.about => [
            _AboutPanel(settings: widget.settings),
          ],
      };
}

/// Version, fingerprint and license, as the core reports them.
class _AboutPanel extends StatefulWidget {
  const _AboutPanel({required this.settings});

  final SettingsViewModel settings;

  @override
  State<_AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<_AboutPanel> {
  String? _version;
  String? _fingerprint;
  String? _license;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final version = await widget.settings.version();
    final fingerprint = await widget.settings.fingerprint();
    final license = await widget.settings.license();
    if (!mounted) return;
    setState(() {
      _version = version;
      _fingerprint = fingerprint;
      _license = license;
    });
  }

  /// A value the core has not returned yet, or returned empty.
  String _value(String? value, String pending) {
    if (value == null) return pending;
    return value.isEmpty ? 'Unavailable' : value;
  }

  @override
  Widget build(BuildContext context) => _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('RustDesk Aurora'),
          _SettingRow(
              icon: LucideIcons.info,
              title: 'Version',
              subtitle: _value(_version, 'Reading…')),
          _SettingRow(
              icon: LucideIcons.fingerprint,
              title: 'Fingerprint',
              subtitle: _value(_fingerprint, 'Reading…')),
          _SettingRow(
              icon: LucideIcons.shieldCheck,
              title: 'License',
              subtitle: _value(_license, 'Reading…')),
        ]),
      );
}

/// Sets the permanent password through the core.
///
/// The core validates and stores it; this only collects it and reports what
/// the core said. A deployment can forbid the change, in which case the form
/// is replaced by an explanation rather than silently failing on submit.
class _PermanentPasswordPanel extends StatefulWidget {
  const _PermanentPasswordPanel({required this.settings});

  final SettingsViewModel settings;

  @override
  State<_PermanentPasswordPanel> createState() =>
      _PermanentPasswordPanelState();
}

class _PermanentPasswordPanelState extends State<_PermanentPasswordPanel> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  String? _success;
  var _saving = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter a password.');
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    final ok = await widget.settings.setPermanentPassword(password);
    if (!mounted) return;
    setState(() {
      _saving = false;
      // The core rejects a password that fails its own rules; say so rather
      // than claiming success.
      _error = ok ? null : 'The password was rejected. Try a longer one.';
      _success = ok ? 'Password updated' : null;
    });
    if (ok) {
      _password.clear();
      _confirm.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.settings.isPasswordChangeDisabled) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Password protection'),
          Text(
            'Your deployment manages this password, so it cannot be changed '
            'here.',
            style: TextStyle(fontSize: 12, color: _muted(context)),
          ),
        ]),
      );
    }

    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Password protection'),
        _SubpageField(
            label: 'New password',
            placeholder: 'Enter a secure password',
            controller: _password,
            obscureText: true),
        const SizedBox(height: 11),
        _SubpageField(
            label: 'Confirm password',
            placeholder: 'Repeat your password',
            controller: _confirm,
            obscureText: true),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!,
              style: const TextStyle(
                  color: CupertinoColors.systemRed, fontSize: 11)),
        ],
        if (_success != null) ...[
          const SizedBox(height: 10),
          Text(_success!,
              style: const TextStyle(color: Color(0xFF6E8C4A), fontSize: 11)),
        ],
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: _SubpageButton(
              label: _saving ? 'Saving…' : 'Set password',
              onTap: _saving ? null : _submit),
        ),
      ]),
    );
  }
}

/// The ID, relay and API servers this client uses.
///
/// The field names are the existing config keys; pointing one at the wrong
/// value sends this client to the wrong network, so the values are read back
/// from the core rather than kept locally.
class _ServerConfigPanel extends StatefulWidget {
  const _ServerConfigPanel({required this.settings});

  final SettingsViewModel settings;

  @override
  State<_ServerConfigPanel> createState() => _ServerConfigPanelState();
}

class _ServerConfigPanelState extends State<_ServerConfigPanel> {
  final _idServer = TextEditingController();
  final _relayServer = TextEditingController();
  final _apiServer = TextEditingController();
  final _key = TextEditingController();

  var _loading = true;
  var _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await widget.settings.serverConfig();
    if (!mounted) return;
    setState(() {
      _idServer.text = config.idServer;
      _relayServer.text = config.relayServer;
      _apiServer.text = config.apiServer;
      _key.text = config.key;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _idServer.dispose();
    _relayServer.dispose();
    _apiServer.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    await widget.settings.setServerConfig(ServerConfig(
      idServer: _idServer.text,
      relayServer: _relayServer.text,
      apiServer: _apiServer.text,
      key: _key.text,
    ));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _status = 'Saved. Reconnect for the change to take effect.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.settings.isServerSettingHidden) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Server connection'),
          Text('Your deployment manages these servers.',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }
    if (_loading) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Server connection'),
          Text('Reading the current configuration…',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }

    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Server connection'),
        _SubpageField(
            label: 'ID server',
            placeholder: 'rustdesk.example.com',
            controller: _idServer),
        const SizedBox(height: 11),
        _SubpageField(
            label: 'Relay server',
            placeholder: 'Leave empty to use the ID server',
            controller: _relayServer),
        const SizedBox(height: 11),
        _SubpageField(
            label: 'API server',
            placeholder: 'https://rustdesk.example.com',
            controller: _apiServer),
        const SizedBox(height: 11),
        _SubpageField(
            label: 'Key',
            placeholder: 'The public key of your server',
            controller: _key),
        if (_status != null) ...[
          const SizedBox(height: 10),
          Text(_status!,
              style: const TextStyle(color: Color(0xFF6E8C4A), fontSize: 11)),
        ],
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          // Typing four server fields on a phone keyboard is error-prone, so
          // the QR code a server hands out fills them in instead.
          if (PlatformFeatures.hasQrScanner) ...[
            _QuietButton(label: 'Scan a code', onTap: _saving ? null : _scan),
            const SizedBox(width: 8),
          ],
          _SubpageButton(
              label: _saving ? 'Saving…' : 'Save',
              onTap: _saving ? null : _save),
        ]),
      ]),
    );
  }

  Future<void> _scan() async {
    final config = await Navigator.of(context).push<ServerConfig>(
        CupertinoPageRoute(
            builder: (_) => ScanConfigPage(settings: widget.settings)));
    if (config == null || !mounted) return;
    // The scan page already wrote it; the fields are reloaded so what is on
    // screen matches what the core now has.
    setState(() {
      _idServer.text = config.idServer;
      _relayServer.text = config.relayServer;
      _apiServer.text = config.apiServer;
      _key.text = config.key;
      _status = 'Scanned. Reconnect for the change to take effect.';
    });
  }
}

/// The plugins the core knows about, and the actions over them.
///
/// Install and uninstall are asynchronous in the core: the request returns
/// immediately and the outcome arrives on the plugin event, so this listens to
/// the adapter rather than assuming the action worked.
class _PluginPanel extends StatefulWidget {
  const _PluginPanel({required this.settings});

  final SettingsViewModel settings;

  @override
  State<_PluginPanel> createState() => _PluginPanelState();
}

class _PluginPanelState extends State<_PluginPanel> {
  @override
  void initState() {
    super.initState();
    widget.settings.pluginChanges.addListener(_onPluginsChanged);
    if (widget.settings.isPluginFeatureEnabled) widget.settings.loadPlugins();
  }

  void _onPluginsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.settings.pluginChanges.removeListener(_onPluginsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.settings.isPluginFeatureEnabled) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Plugins'),
          Text('This build of RustDesk was made without plugin support.',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }

    final failure = widget.settings.pluginFailedReason;
    if (failure.isNotEmpty) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Plugins'),
          Text('The plugin list could not be read.',
              style: TextStyle(fontSize: 12, color: _muted(context))),
          const SizedBox(height: 8),
          Text(failure,
              style: const TextStyle(
                  color: CupertinoColors.systemRed, fontSize: 11)),
        ]),
      );
    }

    if (!widget.settings.arePluginsLoaded) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Plugins'),
          Text('Reading the plugin list…',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }

    final plugins = widget.settings.plugins;
    if (plugins.isEmpty) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Plugins'),
          Text('No plugin is available from your sources.',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }

    return Column(
        children: _withGaps([
      for (final plugin in plugins)
        _PluginCard(plugin: plugin, settings: widget.settings)
    ]));
  }
}

/// One plugin, with what can be done to it right now.
class _PluginCard extends StatelessWidget {
  const _PluginCard({required this.plugin, required this.settings});

  final PluginInfo plugin;
  final SettingsViewModel settings;

  @override
  Widget build(BuildContext context) {
    final enabled =
        plugin.isInstalled && settings.isPluginEnabled(plugin.meta.id);
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Flexible(
                      child: Text(
                          plugin.meta.name.isEmpty
                              ? plugin.meta.id
                              : plugin.meta.name,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 7),
                  Text(plugin.meta.version,
                      style: TextStyle(fontSize: 11, color: _muted(context))),
                ]),
                const SizedBox(height: 3),
                Text(
                    plugin.meta.description.isEmpty
                        ? plugin.source.name
                        : plugin.meta.description,
                    style: TextStyle(fontSize: 12, color: _muted(context))),
              ])),
          if (plugin.isInstalled)
            Transform.scale(
                scale: .78,
                child: CupertinoSwitch(
                    value: enabled,
                    onChanged: plugin.isValid
                        ? (value) => settings.setPluginEnabled(plugin, value)
                        : null)),
        ]),
        // An invalid plugin cannot run; saying why beats a switch that does
        // nothing.
        if (!plugin.isValid) ...[
          const SizedBox(height: 8),
          Text(plugin.invalidReason,
              style: const TextStyle(
                  color: CupertinoColors.systemRed, fontSize: 11)),
        ],
        if (plugin.failedMsg.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(plugin.failedMsg,
              style: const TextStyle(
                  color: CupertinoColors.systemRed, fontSize: 11)),
        ],
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (plugin.needsUpdate) ...[
            _QuietButton(
                label: 'Update to ${plugin.meta.version}',
                onTap: () => settings.installPlugin(plugin)),
            const SizedBox(width: 8),
          ],
          if (plugin.isInstalled)
            _QuietButton(
                label: 'Uninstall',
                onTap: () => settings.uninstallPlugin(plugin))
          else
            _SubpageButton(
                label: 'Install',
                onTap: plugin.isValid
                    ? () => settings.installPlugin(plugin)
                    : null),
        ]),
      ]),
    );
  }
}

/// Remote printing: the outgoing virtual printer, and incoming jobs.
///
/// Outgoing printing depends on the OS and on RustDesk being installed, so the
/// panel reports which of those is missing rather than offering a button that
/// cannot work.
class _PrinterPanel extends StatefulWidget {
  const _PrinterPanel({required this.settings});

  final SettingsViewModel settings;

  @override
  State<_PrinterPanel> createState() => _PrinterPanelState();
}

class _PrinterPanelState extends State<_PrinterPanel> {
  var _loading = true;
  var _installing = false;
  PrinterOptions? _options;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final options = await widget.settings.printerOptions();
    if (!mounted) return;
    setState(() {
      _options = options;
      _loading = false;
    });
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    await widget.settings.installPrinter();
    if (!mounted) return;
    setState(() => _installing = false);
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        _outgoingPanel(context),
        const SizedBox(height: 14),
        _incomingPanel(context),
      ]);

  Widget _outgoingPanel(BuildContext context) {
    final appName = widget.settings.appName;
    final state = widget.settings.outgoingPrinterState;
    final error = widget.settings.printerInstallError;

    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Printing to a remote device'),
        Text(
            switch (state) {
              OutgoingPrinterState.unsupportedOs =>
                'This operating system cannot host the $appName printer.',
              OutgoingPrinterState.clientNotInstalled =>
                'The $appName printer needs an installed copy of $appName, '
                    'not a portable one.',
              OutgoingPrinterState.printerNotInstalled =>
                'Install the $appName printer to print from a remote session '
                    'to a printer here.',
              OutgoingPrinterState.ready =>
                'The $appName printer is installed and ready.',
            },
            style: TextStyle(fontSize: 12, color: _muted(context))),
        if (error.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(error,
              style: const TextStyle(
                  color: CupertinoColors.systemRed, fontSize: 11)),
        ],
        if (state == OutgoingPrinterState.printerNotInstalled) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _SubpageButton(
                label: _installing ? 'Installing…' : 'Install $appName printer',
                onTap: _installing ? null : _install),
          ),
        ],
      ]),
    );
  }

  Widget _incomingPanel(BuildContext context) {
    final options = _options;
    if (_loading || options == null) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Print jobs sent to this device'),
          Text('Reading the printers…',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }

    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Print jobs sent to this device'),
        _SwitchRow(
            icon: LucideIcons.printer,
            title: 'Accept remote print jobs',
            subtitle: 'Let a connected device print through this one',
            value: widget.settings.isRemotePrinterEnabled,
            onChanged: (value) async {
              await widget.settings.setRemotePrinterEnabled(value);
              if (mounted) setState(() {});
            }),
        const SizedBox(height: 6),
        _RadioRow(
            label: 'Dismiss the job',
            description: 'Throw away anything a remote device sends.',
            selected: options.action == IncomingJobAction.dismiss,
            onTap: () => _setAction(IncomingJobAction.dismiss)),
        _RadioRow(
            label: 'Use the default printer',
            description: 'Send it wherever this device normally prints.',
            selected: options.action == IncomingJobAction.useDefault,
            onTap: () => _setAction(IncomingJobAction.useDefault)),
        _RadioRow(
            label: 'Use a chosen printer',
            description: options.printerNames.isEmpty
                ? 'No printer is available on this device.'
                : 'Always print to one printer.',
            selected: options.action == IncomingJobAction.useSelected,
            onTap: options.printerNames.isEmpty
                ? null
                : () => _setAction(IncomingJobAction.useSelected)),
        if (options.printerNames.isNotEmpty && options.canSelectPrinter)
          _SettingSelect(
              icon: LucideIcons.printer,
              title: 'Printer',
              subtitle: 'The printer incoming jobs go to.',
              value: options.printerName.isEmpty
                  ? options.printerNames.first
                  : options.printerName,
              options: options.printerNames,
              onChanged: (value) async {
                await widget.settings.setSelectedPrinter(value);
                await _load();
              }),
        _SwitchRow(
            icon: LucideIcons.zap,
            title: 'Print without asking',
            subtitle: 'Send the job straight to the printer',
            value: options.autoPrint,
            // Dismissed jobs never reach a printer, so this would do nothing.
            lockReason:
                options.canAutoPrint ? null : 'Jobs are being dismissed',
            onChanged: (value) async {
              await widget.settings.setPrinterAutoPrint(value);
              await _load();
            }),
      ]),
    );
  }

  Future<void> _setAction(IncomingJobAction action) async {
    await widget.settings.setIncomingJobAction(action);
    await _load();
  }
}

/// One choice in a mutually exclusive group.
class _RadioRow extends StatelessWidget {
  const _RadioRow(
      {required this.label,
      required this.description,
      required this.selected,
      required this.onTap});

  final String label;
  final String description;
  final bool selected;

  /// Null when the choice cannot be made, which greys the row out.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? .55 : 1,
        child: HoverTap(
          radius: 8,
          onTap: onTap ?? () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(children: [
              Icon(selected ? LucideIcons.circleDot : LucideIcons.circle,
                  size: 16,
                  color: selected
                      ? CupertinoTheme.of(context).primaryColor
                      : _muted(context)),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(description,
                        style: TextStyle(fontSize: 11, color: _muted(context))),
                  ])),
            ]),
          ),
        ),
      );
}

/// Two-factor authentication, its Telegram bot, and the trusted devices.
///
/// Enrolment is the legacy order: the core generates a secret, the user proves
/// they stored it by entering a code, and only then is 2FA on. Turning it off
/// also drops the trusted devices, because those exist to skip it.
class _TwoFactorPanel extends StatefulWidget {
  const _TwoFactorPanel({required this.settings});

  final SettingsViewModel settings;

  @override
  State<_TwoFactorPanel> createState() => _TwoFactorPanelState();
}

class _TwoFactorPanelState extends State<_TwoFactorPanel> {
  final _code = TextEditingController();
  final _botToken = TextEditingController();

  /// The `otpauth://` URI being enrolled, or empty when not enrolling.
  var _enrolmentUri = '';
  var _busy = false;

  /// A problem with enrolment. The bot keeps its own, so a bot error is not
  /// shown against the 2FA setup step and vice versa.
  String? _error;
  String? _botError;

  var _loadingDevices = false;
  List<TrustedDevice> _devices = const [];
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.settings.areTrustedDevicesEnabled) _loadDevices();
  }

  @override
  void dispose() {
    _code.dispose();
    _botToken.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    setState(() => _loadingDevices = true);
    final devices = await widget.settings.trustedDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _selected.removeWhere(
          (key) => !devices.any((device) => device.hwidKey == key));
      _loadingDevices = false;
    });
  }

  Future<void> _startEnrolment() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final uri = await widget.settings.generateTwoFactorSecret();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _enrolmentUri = uri;
      // Without a URI there is nothing to scan, so say so rather than showing
      // an empty QR code.
      _error = uri.isEmpty ? 'Could not start setup. Try again.' : null;
    });
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.settings.verifyTwoFactor(_code.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = ok ? null : 'That code was not accepted. Try the next one.';
      if (ok) {
        _enrolmentUri = '';
        _code.clear();
      }
    });
    if (ok && widget.settings.areTrustedDevicesEnabled) await _loadDevices();
  }

  Future<void> _disable() async {
    setState(() => _busy = true);
    await widget.settings.disableTwoFactor();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _enrolmentUri = '';
      _devices = const [];
      _selected.clear();
      _error = null;
    });
  }

  Future<void> _setTrustedDevices(bool enabled) async {
    await widget.settings.setTrustedDevicesEnabled(enabled);
    if (!mounted) return;
    if (enabled) {
      await _loadDevices();
    } else {
      setState(() {
        _devices = const [];
        _selected.clear();
      });
    }
  }

  Future<void> _removeSelected() async {
    final removing = [
      for (final device in _devices)
        if (_selected.contains(device.hwidKey)) device
    ];
    if (removing.isEmpty) return;
    await widget.settings
        .removeTrustedDevices(removing, total: _devices.length);
    if (!mounted) return;
    await _loadDevices();
  }

  Future<void> _submitBot() async {
    setState(() {
      _busy = true;
      _botError = null;
    });
    final error = await widget.settings.verifyTelegramBot(_botToken.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _botError = error;
      if (error == null) _botToken.clear();
    });
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        _statusPanel(context),
        if (widget.settings.isTwoFactorEnabled) ...[
          const SizedBox(height: 14),
          _botPanel(context),
          const SizedBox(height: 14),
          _trustedDevicesPanel(context),
        ],
      ]);

  Widget _statusPanel(BuildContext context) {
    final enabled = widget.settings.isTwoFactorEnabled;
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Verification'),
        _DiagnosticsRow(
            label: 'Two-factor authentication', value: enabled ? 'On' : 'Off'),
        if (enabled) ...[
          const SizedBox(height: 8),
          Text(
              'Anyone connecting to this device must enter a code from your '
              'authenticator app. Turning this off also removes every trusted '
              'device.',
              style: TextStyle(fontSize: 12, color: _muted(context))),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _SubpageButton(
                label: _busy ? 'Working…' : 'Turn off',
                onTap: _busy ? null : _disable),
          ),
        ] else if (_enrolmentUri.isEmpty) ...[
          const SizedBox(height: 8),
          Text(
              'Scan a code with an authenticator app, then confirm it here to '
              'turn this on.',
              style: TextStyle(fontSize: 12, color: _muted(context))),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(
                    color: CupertinoColors.systemRed, fontSize: 11)),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _SubpageButton(
                label: _busy ? 'Preparing…' : 'Set up',
                onTap: _busy ? null : _startEnrolment),
          ),
        ] else
          ..._enrolmentSteps(context),
      ]),
    );
  }

  List<Widget> _enrolmentSteps(BuildContext context) {
    final secret = widget.settings.twoFactorSecretOf(_enrolmentUri);
    return [
      const SizedBox(height: 10),
      Text('Scan this with your authenticator app.',
          style: TextStyle(fontSize: 12, color: _muted(context))),
      const SizedBox(height: 12),
      Center(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: CupertinoColors.white,
              borderRadius: BorderRadius.circular(10)),
          child: QrImageView(
              data: _enrolmentUri,
              version: QrVersions.auto,
              size: 160,
              backgroundColor: CupertinoColors.white),
        ),
      ),
      if (secret.isNotEmpty) ...[
        const SizedBox(height: 12),
        // Some authenticator apps cannot scan; the typed secret is the same
        // enrolment by another route.
        Text('Or enter this key manually:',
            style: TextStyle(fontSize: 11, color: _muted(context))),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
              child: Text(secret,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600))),
          HoverTap(
              radius: 8,
              onTap: () => Clipboard.setData(ClipboardData(text: secret)),
              child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(LucideIcons.copy, size: 14))),
        ]),
      ],
      const SizedBox(height: 14),
      _SubpageField(
          label: 'Verification code', placeholder: '000000', controller: _code),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!,
            style: const TextStyle(
                color: CupertinoColors.systemRed, fontSize: 11)),
      ],
      const SizedBox(height: 14),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        _QuietButton(
            label: 'Cancel',
            onTap: _busy
                ? null
                : () => setState(() {
                      _enrolmentUri = '';
                      _code.clear();
                      _error = null;
                    })),
        const SizedBox(width: 8),
        _SubpageButton(
            label: _busy ? 'Checking…' : 'Confirm',
            onTap: _busy ? null : _verify),
      ]),
    ];
  }

  Widget _botPanel(BuildContext context) {
    final hasBot = widget.settings.hasTelegramBot;
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Telegram bot'),
        Text(
            hasBot
                ? 'Verification codes are also sent through your Telegram bot.'
                : 'Optionally receive the verification code in Telegram.',
            style: TextStyle(fontSize: 12, color: _muted(context))),
        if (hasBot) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _QuietButton(
                label: 'Remove bot',
                onTap: _busy
                    ? null
                    : () async {
                        await widget.settings.removeTelegramBot();
                        if (mounted) setState(() {});
                      }),
          ),
        ] else ...[
          const SizedBox(height: 12),
          _SubpageField(
              label: 'Bot token',
              placeholder: 'The token from @BotFather',
              controller: _botToken),
          if (_botError != null) ...[
            const SizedBox(height: 10),
            Text(_botError!,
                style: const TextStyle(
                    color: CupertinoColors.systemRed, fontSize: 11)),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _SubpageButton(
                label: _busy ? 'Checking…' : 'Add bot',
                onTap: _busy ? null : _submitBot),
          ),
        ],
      ]),
    );
  }

  Widget _trustedDevicesPanel(BuildContext context) {
    final allowed = widget.settings.areTrustedDevicesEnabled;
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Trusted devices'),
        _SwitchRow(
            icon: LucideIcons.laptop,
            title: 'Allow trusted devices',
            subtitle:
                'Let a device skip the code for 90 days after it verifies',
            value: allowed,
            onChanged: _busy ? (_) {} : _setTrustedDevices),
        if (allowed) ...[
          const SizedBox(height: 8),
          if (_loadingDevices)
            Text('Reading the trusted devices…',
                style: TextStyle(fontSize: 12, color: _muted(context)))
          else if (_devices.isEmpty)
            Text('No device has been trusted yet.',
                style: TextStyle(fontSize: 12, color: _muted(context)))
          else ...[
            for (final device in _devices)
              _TrustedDeviceRow(
                  device: device,
                  selected: _selected.contains(device.hwidKey),
                  onChanged: (value) => setState(() {
                        if (value) {
                          _selected.add(device.hwidKey);
                        } else {
                          _selected.remove(device.hwidKey);
                        }
                      })),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: _SubpageButton(
                  label: 'Remove selected',
                  icon: LucideIcons.trash2,
                  onTap: _selected.isEmpty ? null : _removeSelected),
            ),
          ],
        ],
      ]),
    );
  }
}

/// One trusted device, with how long it may still skip the code.
class _TrustedDeviceRow extends StatelessWidget {
  const _TrustedDeviceRow(
      {required this.device, required this.selected, required this.onChanged});

  final TrustedDevice device;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final days = device.daysRemaining();
    return HoverTap(
      radius: 8,
      onTap: () => onChanged(!selected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(children: [
          Icon(selected ? LucideIcons.squareCheck : LucideIcons.square,
              size: 16),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(device.name.isEmpty ? device.id : device.name,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${device.platform} · ${device.id}',
                    style: TextStyle(fontSize: 11, color: _muted(context))),
              ])),
          Text(days == 0 ? 'Expired' : '$days days left',
              style: TextStyle(fontSize: 11, color: _muted(context))),
        ]),
      ),
    );
  }
}

/// The SOCKS5/HTTP proxy the core routes connections through.
///
/// The address is checked with the core before it is saved, the way the legacy
/// dialog checked it, so a typo is reported here instead of failing silently on
/// the next connection.
class _ProxyPanel extends StatefulWidget {
  const _ProxyPanel({required this.settings});

  final SettingsViewModel settings;

  @override
  State<_ProxyPanel> createState() => _ProxyPanelState();
}

class _ProxyPanelState extends State<_ProxyPanel> {
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  var _loading = true;
  var _saving = false;
  var _active = false;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await widget.settings.proxyConfig();
    final active = await widget.settings.isProxyActive();
    if (!mounted) return;
    setState(() {
      _address.text = config.address;
      _username.text = config.username;
      _password.text = config.password;
      _active = active;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _status = null;
    });

    // An empty address clears the proxy, so it skips the reachability check.
    final problem = await widget.settings.validateProxyAddress(_address.text);
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _saving = false;
        _error = problem;
      });
      return;
    }

    final saved = await widget.settings.setProxyConfig(ProxyConfig(
      address: _address.text,
      username: _username.text,
      password: _password.text,
    ));
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _saving = false;
        _error = 'Your deployment manages the proxy.';
      });
      return;
    }

    final active = await widget.settings.isProxyActive();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _active = active;
      _status = _address.text.trim().isEmpty ? 'Proxy removed' : 'Proxy saved';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.settings.isProxySettingHidden) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Proxy'),
          Text('Your deployment manages the proxy.',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }
    if (_loading) {
      return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _PanelTitle('Proxy'),
          Text('Reading the current proxy…',
              style: TextStyle(fontSize: 12, color: _muted(context))),
        ]),
      );
    }

    final locked = widget.settings.isProxyFixed;
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _PanelTitle('Proxy'),
        _DiagnosticsRow(
            label: 'Status', value: _active ? 'In use' : 'Not in use'),
        const SizedBox(height: 8),
        _SubpageField(
            label: 'Server',
            placeholder: 'socks5://127.0.0.1:1080',
            controller: _address,
            enabled: !locked),
        const SizedBox(height: 11),
        _SubpageField(
            label: 'Username',
            placeholder: 'Leave empty if the proxy needs no sign-in',
            controller: _username,
            enabled: !locked),
        const SizedBox(height: 11),
        _SubpageField(
            label: 'Password',
            placeholder: 'Leave empty if the proxy needs no sign-in',
            controller: _password,
            obscureText: true,
            enabled: !locked),
        if (locked) ...[
          const SizedBox(height: 10),
          Text('Your deployment pinned this proxy.',
              style: TextStyle(fontSize: 11, color: _muted(context))),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!,
              style: const TextStyle(
                  color: CupertinoColors.systemRed, fontSize: 11)),
        ],
        if (_status != null) ...[
          const SizedBox(height: 10),
          Text(_status!,
              style: const TextStyle(color: Color(0xFF6E8C4A), fontSize: 11)),
        ],
        if (!locked) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _SubpageButton(
                label: _saving ? 'Saving…' : 'Save',
                onTap: _saving ? null : _save),
          ),
        ],
      ]),
    );
  }
}

class _SubpageField extends StatelessWidget {
  const _SubpageField(
      {required this.label,
      required this.placeholder,
      this.obscureText = false,
      this.enabled = true,
      this.controller});
  final String label;
  final String placeholder;
  final bool obscureText;

  /// False when a deployment pinned the value, which greys the field out
  /// rather than accepting edits the core would discard.
  final bool enabled;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Opacity(
            opacity: enabled ? 1 : .55,
            child: CupertinoTextField(
                controller: controller,
                placeholder: placeholder,
                obscureText: obscureText,
                enabled: enabled,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: _inputDecoration(context))),
      ]);
}

class _DiagnosticsRow extends StatelessWidget {
  const _DiagnosticsRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const Icon(LucideIcons.checkCircle, size: 16, color: Color(0xFFB55433)),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600))),
        Text(value, style: TextStyle(fontSize: 11, color: _muted(context)))
      ]));
}

class _SubpageButton extends StatelessWidget {
  const _SubpageButton({required this.label, required this.onTap, this.icon});
  final String label;
  final IconData? icon;

  /// Null while an action is in flight, which disables the button.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
              color: CupertinoTheme.of(context)
                  .primaryColor
                  // A disabled button reads as inactive rather than dead.
                  .withValues(alpha: onTap == null ? .5 : 1),
              borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: CupertinoColors.white),
              const SizedBox(width: 7),
            ],
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: CupertinoColors.white))
          ])));
}

/// A secondary action next to a [_SubpageButton], for cancelling or undoing.
class _QuietButton extends StatelessWidget {
  const _QuietButton({required this.label, required this.onTap});
  final String label;

  /// Null while an action is in flight, which disables the button.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Opacity(
          opacity: onTap == null ? .5 : 1,
          child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                  border: Border.all(
                      color: const Color(0xFFD9B8A8).withValues(alpha: .7)),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)))));
}

class _SettingSelect extends StatefulWidget {
  const _SettingSelect(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.value,
      required this.options,
      required this.onChanged});
  final IconData icon;
  final String title;
  final String subtitle;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  State<_SettingSelect> createState() => _SettingSelectState();
}

class _SettingSelectState extends State<_SettingSelect> {
  final _link = LayerLink();
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _overlay?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(widget.icon, size: 17),
        const SizedBox(width: 11),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(widget.subtitle,
              style: TextStyle(fontSize: 11, color: _muted(context)))
        ])),
        CompositedTransformTarget(
            link: _link,
            child: HoverTap(
                radius: 8,
                onTap: _toggle,
                child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
                    decoration: _inputDecoration(context)
                        .copyWith(borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.value,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      const Icon(LucideIcons.chevronDown, size: 14)
                    ]))))
      ]));

  void _toggle() {
    if (_overlay != null) {
      _overlay?.remove();
      _overlay = null;
      return;
    }
    _overlay = OverlayEntry(
        builder: (context) => Stack(children: [
              Positioned.fill(
                  child: GestureDetector(
                      onTap: _toggle, behavior: HitTestBehavior.translucent)),
              CompositedTransformFollower(
                  link: _link,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomRight,
                  followerAnchor: Alignment.topRight,
                  offset: const Offset(0, 6),
                  child: _CompactSelectMenu(
                      selected: widget.value,
                      options: widget.options,
                      onSelect: (value) {
                        widget.onChanged(value);
                        _toggle();
                      }))
            ]));
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }
}

class _CompactSelectMenu extends StatelessWidget {
  const _CompactSelectMenu(
      {required this.selected, required this.options, required this.onSelect});
  final String selected;
  final List<String> options;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Container(
      width: 190,
      padding: const EdgeInsets.all(5),
      decoration: panelDecoration(context),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          children: options
              .map((option) => GestureDetector(
                  onTap: () => onSelect(option),
                  child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                          color: option == selected
                              ? CupertinoTheme.of(context)
                                  .primaryColor
                                  .withValues(alpha: .12)
                              : null,
                          borderRadius: BorderRadius.circular(8)),
                      child: Row(children: [
                        Expanded(
                            child: Text(option,
                                style: const TextStyle(fontSize: 12))),
                        if (option == selected)
                          const Icon(LucideIcons.check, size: 14)
                      ]))))
              .toList()));
}

class _AppearancePicker extends StatefulWidget {
  const _AppearancePicker({required this.brightness, required this.onChanged});
  final Brightness brightness;
  final ValueChanged<Brightness> onChanged;
  @override
  State<_AppearancePicker> createState() => _AppearancePickerState();
}

class _AppearancePickerState extends State<_AppearancePicker> {
  final _link = LayerLink();
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _overlay?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = widget.brightness == Brightness.dark ? 'Dark' : 'Light';
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          const Icon(LucideIcons.paintbrush, size: 17),
          const SizedBox(width: 11),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Appearance',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('Choose the app surface.',
                    style: TextStyle(fontSize: 11, color: _muted(context)))
              ])),
          CompositedTransformTarget(
              link: _link,
              child: HoverTap(
                  radius: 8,
                  onTap: _toggle,
                  child: Container(
                      key: const Key('appearance-select'),
                      padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
                      decoration: _inputDecoration(context)
                          .copyWith(borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(appearance,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        const Icon(LucideIcons.chevronDown, size: 14)
                      ]))))
        ]));
  }

  void _toggle() {
    if (_overlay != null) {
      _overlay?.remove();
      _overlay = null;
      return;
    }
    _overlay = OverlayEntry(
        builder: (context) => Stack(children: [
              Positioned.fill(
                  child: GestureDetector(
                      onTap: _toggle, behavior: HitTestBehavior.translucent)),
              CompositedTransformFollower(
                  link: _link,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomRight,
                  followerAnchor: Alignment.topRight,
                  offset: const Offset(0, 6),
                  child: _AppearanceMenu(
                      selected: widget.brightness,
                      onSelect: (value) {
                        widget.onChanged(value);
                        _toggle();
                      })),
            ]));
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }
}

class _AppearanceMenu extends StatelessWidget {
  const _AppearanceMenu({required this.selected, required this.onSelect});
  final Brightness selected;
  final ValueChanged<Brightness> onSelect;
  @override
  Widget build(BuildContext context) => Container(
        width: 178,
        padding: const EdgeInsets.all(5),
        decoration: panelDecoration(context),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _MenuOption(
              icon: LucideIcons.sun,
              label: 'Light',
              selected: selected == Brightness.light,
              onTap: () => onSelect(Brightness.light)),
          _MenuOption(
              icon: LucideIcons.moon,
              label: 'Dark',
              selected: selected == Brightness.dark,
              onTap: () => onSelect(Brightness.dark)),
        ]),
      );
}

class _MenuOption extends StatelessWidget {
  const _MenuOption(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
              color: selected
                  ? CupertinoTheme.of(context)
                      .primaryColor
                      .withValues(alpha: .12)
                  : null,
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Icon(icon, size: 16),
            const SizedBox(width: 9),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            if (selected) const Icon(LucideIcons.check, size: 14)
          ])));
}

/// The icon representing a peer's reported platform.
IconData _platformIcon(String platform) {
  switch (platform) {
    case PeerPlatform.windows:
      return LucideIcons.monitorCog;
    case PeerPlatform.macOS:
      return LucideIcons.monitor;
    case PeerPlatform.android:
      return LucideIcons.smartphone;
    case PeerPlatform.linux:
      return LucideIcons.laptop;
    case PeerPlatform.webDesktop:
      return LucideIcons.globe;
    default:
      return LucideIcons.monitor;
  }
}

/// The secondary line on a device card: platform and presence, plus the
/// account name when the peer reports one.
String _peerSubtitle(Peer peer) {
  final parts = <String>[
    if (peer.platform.isNotEmpty) peer.platform,
    peer.online ? 'Online' : 'Offline',
  ];
  if (peer.username.isNotEmpty) parts.add(peer.username);
  return parts.join(' · ');
}

class _DeviceGrid extends StatelessWidget {
  const _DeviceGrid({
    required this.peers,
    required this.state,
    required this.onOpenSession,
    this.error,
    this.limit,
    this.isFiltered = false,
    this.onToggleFavorite,
    this.onRemove,
    this.onSetAlias,
    this.onForgetPassword,
    this.isFavorite,
  });

  final List<Peer> peers;
  final LoadState state;
  final Object? error;
  final ValueChanged<String> onOpenSession;
  final int? limit;

  /// Whether a search or the online filter is narrowing the list, so the
  /// empty state can say why nothing is shown.
  final bool isFiltered;

  final Future<void> Function(String)? onToggleFavorite;
  final Future<bool> Function(String)? onRemove;
  final Future<void> Function(String, String)? onSetAlias;
  final Future<void> Function(String)? onForgetPassword;
  final bool Function(String)? isFavorite;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case LoadState.loading:
        return const _DevicesPlaceholder(
          icon: LucideIcons.loaderCircle,
          title: 'Loading devices…',
          detail: 'Reading the device list from the RustDesk service.',
        );
      case LoadState.error:
        return _DevicesPlaceholder(
          icon: LucideIcons.triangleAlert,
          title: 'Could not load devices',
          detail:
              error?.toString() ?? 'The device list is unavailable right now.',
        );
      case LoadState.empty:
      case LoadState.ready:
        break;
    }

    final visible = limit == null ? peers : peers.take(limit!).toList();
    if (visible.isEmpty) {
      return _DevicesPlaceholder(
        icon: LucideIcons.monitor,
        title: isFiltered ? 'No matching devices' : 'No devices yet',
        detail: isFiltered
            ? 'Try another search or remove the online filter.'
            : 'Devices appear here after your first connection.',
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      // Compact rows fit more per screen; keep a ~250px minimum so the
      // subtitle stays readable before ellipsizing.
      final columns = constraints.maxWidth > 1120
          ? 4
          : constraints.maxWidth > 840
              ? 3
              : constraints.maxWidth > 500
                  ? 2
                  : 1;
      const spacing = 8.0;
      final cellWidth =
          (constraints.maxWidth - spacing * (columns - 1)) / columns;
      return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          // A fixed row height keeps cards compact at any column count.
          childAspectRatio: cellWidth / 48,
          children: [
            for (final peer in visible)
              _DeviceCard(
                peer: peer,
                isFavorite: isFavorite?.call(peer.id) ?? false,
                onTap: () => onOpenSession(peer.id),
                onToggleFavorite: onToggleFavorite,
                onRemove: onRemove,
                onSetAlias: onSetAlias,
                onForgetPassword: onForgetPassword,
              )
          ]);
    });
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.peer,
    required this.isFavorite,
    required this.onTap,
    this.onToggleFavorite,
    this.onRemove,
    this.onSetAlias,
    this.onForgetPassword,
  });

  final Peer peer;
  final bool isFavorite;
  final VoidCallback onTap;
  final Future<void> Function(String)? onToggleFavorite;
  final Future<bool> Function(String)? onRemove;
  final Future<void> Function(String, String)? onSetAlias;
  final Future<void> Function(String)? onForgetPassword;

  bool get _hasActions =>
      onToggleFavorite != null ||
      onRemove != null ||
      onSetAlias != null ||
      onForgetPassword != null;

  @override
  Widget build(BuildContext context) => HoverTap(
      onTap: onTap,
      child: _Panel(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(children: [
            Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: CupertinoTheme.of(context)
                        .primaryColor
                        .withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(7)),
                child: Icon(_platformIcon(peer.platform), size: 15)),
            const SizedBox(width: 9),
            Expanded(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(children: [
                    Flexible(
                      child: Text(
                        // The alias, or the id when there is none.
                        peer.alias.isNotEmpty
                            ? peer.alias
                            : formatPeerId(peer.id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (isFavorite)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(LucideIcons.star,
                            size: 10, color: Color(0xFFB55433)),
                      ),
                  ]),
                  const SizedBox(height: 1),
                  Text(_peerSubtitle(peer),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: _muted(context)))
                ])),
            Icon(LucideIcons.circle,
                size: 7,
                color: peer.online ? const Color(0xFFB55433) : _muted(context)),
            if (_hasActions) ...[
              const SizedBox(width: 2),
              AnchoredMenu(
                width: 186,
                actions: _actions(context),
                builder: (context, open) => MenuTrigger(
                  open: open,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Icon(LucideIcons.ellipsisVertical, size: 15),
                  ),
                ),
              ),
            ],
          ])));

  List<MenuAction> _actions(BuildContext context) => [
        MenuAction(
            icon: LucideIcons.arrowRight, label: 'Connect', onTap: onTap),
        if (onToggleFavorite != null)
          MenuAction(
            icon: LucideIcons.star,
            label: isFavorite ? 'Remove from favorites' : 'Add to favorites',
            onTap: () => onToggleFavorite!(peer.id),
          ),
        if (onSetAlias != null)
          MenuAction(
            icon: LucideIcons.pencil,
            label: peer.alias.isEmpty ? 'Set alias' : 'Rename',
            onTap: () => _promptForAlias(context),
          ),
        if (onForgetPassword != null)
          MenuAction(
            icon: LucideIcons.keyRound,
            label: 'Forget password',
            onTap: () => onForgetPassword!(peer.id),
          ),
        if (onRemove != null)
          MenuAction(
            icon: LucideIcons.trash2,
            label: 'Remove',
            isDestructive: true,
            onTap: () => onRemove!(peer.id),
          ),
      ];

  Future<void> _promptForAlias(BuildContext context) async {
    final controller = TextEditingController(text: peer.alias);
    final alias = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Device alias'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            autofocus: true,
            placeholder: formatPeerId(peer.id),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (alias == null) return;
    await onSetAlias!(peer.id, alias);
  }
}

/// Loading, empty and error states for a device list.
class _DevicesPlaceholder extends StatelessWidget {
  const _DevicesPlaceholder({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => _Panel(
          child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 32),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(detail,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: _muted(context)))
      ])));
}

class _Pulse extends StatelessWidget {
  const _Pulse({required this.model});
  final WorkspaceViewModel model;

  @override
  Widget build(BuildContext context) {
    // Counts are unknown until the peer lists have loaded at least once.
    final loading = model.loadStateOf(PeerScope.recent) == LoadState.loading;
    String count(int value) => loading ? '—' : '$value';
    return _Panel(
        child: Wrap(spacing: 38, runSpacing: 16, children: [
      _Metric(count(model.knownPeerCount), 'Known devices'),
      _Metric(count(model.onlineCount), 'Available now'),
      _Metric(count(model.peersOf(PeerScope.favorite).length), 'Favorites'),
    ]));
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.value, this.label);
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 122,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 11, color: _muted(context)))
      ]));
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700))),
        if (action != null)
          GestureDetector(
              onTap: onAction,
              child: Text(action!,
                  style: TextStyle(
                      fontSize: 12,
                      color: CupertinoTheme.of(context).primaryColor,
                      fontWeight: FontWeight.w600)))
      ]);
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)));
}

class _SettingRow extends StatelessWidget {
  const _SettingRow(
      {required this.icon,
      required this.title,
      required this.subtitle,
      this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(icon, size: 17),
          const SizedBox(width: 11),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(fontSize: 11, color: _muted(context)))
              ])),
          if (onTap != null) const Icon(LucideIcons.chevronRight, size: 15)
        ]));
    return onTap == null ? child : HoverTap(onTap: onTap!, child: child);
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.value,
      required this.onChanged,
      this.lockReason});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Why this cannot be changed, when a deployment pins it or the platform
  /// does not support it. A locked switch says so instead of springing back.
  final String? lockReason;

  bool get _isLocked => lockReason != null;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: _isLocked ? .55 : 1,
        child: Row(children: [
          Expanded(
              child: _SettingRow(
                  icon: icon,
                  title: title,
                  subtitle: _isLocked ? '$subtitle · $lockReason' : subtitle)),
          Transform.scale(
              scale: .78,
              child: CupertinoSwitch(
                  value: value, onChanged: _isLocked ? null : onChanged))
        ]),
      );
}

/// A group of switches backed by real option keys.
class _SettingToggleGroup extends StatelessWidget {
  const _SettingToggleGroup({
    required this.model,
    required this.toggles,
    required this.icon,
  });

  final SettingsViewModel model;
  final List<SettingToggle> toggles;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final state in model.statesOf(toggles))
            _SwitchRow(
              // Keyed by option key so a test — and a screen reader — can
              // identify which setting a switch belongs to.
              key: Key('setting-${state.toggle.key}'),
              icon: icon,
              title: state.toggle.label,
              subtitle: state.toggle.description,
              value: state.value,
              lockReason: state.lockReason,
              onChanged: (_) => model.toggle(state.toggle),
            ),
        ],
      );
}

class _TogglePill extends StatelessWidget {
  const _TogglePill(
      {required this.label, required this.enabled, required this.onTap});
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: enabled
                  ? CupertinoTheme.of(context)
                      .primaryColor
                      .withValues(alpha: .15)
                  : CupertinoColors.systemGrey.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(99)),
          child: Text(label,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))));
}

class _OnlinePill extends StatelessWidget {
  const _OnlinePill({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: online
                ? const Color(0xFFB55433).withValues(alpha: .13)
                : muted.withValues(alpha: .13),
            borderRadius: BorderRadius.circular(99)),
        child: Text(online ? 'Online' : 'Offline',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: online ? const Color(0xFF8C402A) : muted)));
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();
  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
          color: CupertinoTheme.of(context).primaryColor.withValues(alpha: .09),
          borderRadius: BorderRadius.circular(13)),
      child:
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(LucideIcons.lockKeyhole, size: 16),
        SizedBox(height: 8),
        Text('Private by default',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        SizedBox(height: 3),
        Text('Every connection is encrypted.', style: TextStyle(fontSize: 10))
      ]));
}

class _Mark extends StatelessWidget {
  const _Mark();
  @override
  Widget build(BuildContext context) => Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
          color: const Color(0xFFA64B30),
          borderRadius: BorderRadius.circular(8)),
      child:
          const Icon(LucideIcons.zap, color: CupertinoColors.white, size: 16));
}

class _Avatar extends StatelessWidget {
  const _Avatar();
  @override
  Widget build(BuildContext context) => Container(
      width: 31,
      height: 31,
      alignment: Alignment.center,
      decoration:
          const BoxDecoration(color: Color(0xFFEACABC), shape: BoxShape.circle),
      child: const Text('A',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF623221))));
}

class _CompactButton extends StatelessWidget {
  const _CompactButton({required this.icon, this.label, required this.onTap});
  final IconData icon;
  final String? label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          decoration: panelDecoration(context),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16),
            if (label != null) ...[
              const SizedBox(width: 6),
              Text(label!, style: const TextStyle(fontSize: 12))
            ]
          ])));
}

class _LightButton extends StatelessWidget {
  const _LightButton(
      {required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: CupertinoColors.white,
              borderRadius: BorderRadius.circular(9)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF713220),
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 7),
            Icon(icon, size: 14, color: const Color(0xFF713220))
          ])));
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(18)});
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Container(
      padding: padding, decoration: panelDecoration(context), child: child);
}

BoxDecoration _inputDecoration(BuildContext context) => BoxDecoration(
    color: (CupertinoTheme.of(context).brightness == Brightness.dark
            ? const Color(0xFF281E1A)
            : CupertinoColors.white)
        .withValues(alpha: .82),
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: const Color(0xFFD9B8A8).withValues(alpha: .7)));
Color _muted(BuildContext context) =>
    CupertinoTheme.of(context).brightness == Brightness.dark
        ? const Color(0xFFCAB6AD)
        : const Color(0xFF806B63);

class _CommandDialog extends StatefulWidget {
  const _CommandDialog({required this.model, required this.onConnect});
  final WorkspaceViewModel model;
  final ValueChanged<String> onConnect;
  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  final controller = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// Known peers matching the query, so the palette can connect by name
  /// rather than requiring an exact id.
  List<Peer> get _matches {
    final peers = filterPeers(widget.model.allKnownPeers, _query);
    return peers.take(5).toList();
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 440,
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(16),
          decoration: panelDecoration(context).copyWith(
            color: CupertinoTheme.of(context).brightness == Brightness.dark
                ? const Color(0xFF2B1C17)
                : const Color(0xFFFFFCF9),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(LucideIcons.command, size: 17),
              const SizedBox(width: 9),
              const Expanded(
                  child: Text('Command palette',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700))),
              GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(LucideIcons.x, size: 17)),
            ]),
            const SizedBox(height: 15),
            CupertinoTextField(
              controller: controller,
              autofocus: true,
              placeholder: 'Connect to a device ID or name',
              onChanged: (value) => setState(() => _query = value),
              onSubmitted: _connect,
              prefix: const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Icon(LucideIcons.search, size: 15)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              decoration: _inputDecoration(context),
            ),
            const SizedBox(height: 10),
            // Matching known devices, so a name is enough to connect.
            for (final peer in _matches)
              _CommandOption(
                  icon: _platformIcon(peer.platform),
                  title: peer.alias.isNotEmpty
                      ? '${peer.alias} · ${formatPeerId(peer.id)}'
                      : formatPeerId(peer.id),
                  hint: peer.online ? 'Online' : null,
                  onTap: () => _connect(peer.id)),
            if (controller.text.trim().isNotEmpty && _matches.isEmpty)
              _CommandOption(
                  icon: LucideIcons.arrowRight,
                  title: 'Connect to ${controller.text.trim()}',
                  hint: 'Enter',
                  onTap: () => _connect(controller.text)),
            if (controller.text.trim().isEmpty && _matches.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Text(
                  widget.model.knownPeerCount == 0
                      ? 'No known devices yet — type an ID to connect.'
                      : 'Type an ID or a device name.',
                  style: TextStyle(fontSize: 11, color: _muted(context)),
                ),
              ),
          ]),
        ),
      );

  void _connect(String value) {
    final id = value.trim();
    // An empty palette entry has nothing to connect to.
    if (id.isEmpty) return;
    Navigator.pop(context);
    widget.onConnect(id);
  }
}

class _CommandOption extends StatelessWidget {
  const _CommandOption(
      {required this.icon,
      required this.title,
      required this.onTap,
      this.hint});
  final IconData icon;
  final String title;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Icon(icon, size: 16),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 12))),
            if (hint != null)
              Text(hint!,
                  style: TextStyle(fontSize: 10, color: _muted(context))),
          ]),
        ),
      );
}

class _NotificationDialog extends StatelessWidget {
  const _NotificationDialog({required this.model, this.updateUrl});
  final WorkspaceViewModel model;
  final String? updateUrl;

  /// Conditions worth surfacing, derived from real service state. An empty
  /// list means genuinely nothing to report.
  List<(IconData, String, String)> _notices() {
    final identity = model.identity;
    final notices = <(IconData, String, String)>[];
    if (identity.hasError) {
      notices.add((
        LucideIcons.triangleAlert,
        'Service status unavailable',
        '${identity.error}',
      ));
    }
    if (!identity.isLoading && !identity.isServiceRunning) {
      notices.add((
        LucideIcons.circlePause,
        'Sharing is stopped',
        'This device refuses incoming connections until sharing is on.',
      ));
    }
    if (!identity.isLoading &&
        identity.isServiceRunning &&
        !identity.isOnline) {
      notices.add((
        LucideIcons.wifiOff,
        'Not registered with the server',
        'Others cannot reach this device until it reconnects.',
      ));
    }
    if (updateUrl != null) {
      notices.add((
        LucideIcons.download,
        'Update available',
        'A newer version of RustDesk is ready to download.',
      ));
    }
    return notices;
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 360,
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(17),
          decoration: panelDecoration(context).copyWith(
            color: CupertinoTheme.of(context).brightness == Brightness.dark
                ? const Color(0xFF2B1C17)
                : const Color(0xFFFFFCF9),
          ),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(LucideIcons.bell, size: 17),
                  const SizedBox(width: 9),
                  const Expanded(
                      child: Text('Notifications',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700))),
                  GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Icon(LucideIcons.x, size: 17)),
                ]),
                const SizedBox(height: 16),
                if (_notices().isEmpty) ...[
                  const _NotificationRow(
                      icon: LucideIcons.shieldCheck,
                      title: 'Your workspace is healthy',
                      subtitle: 'The service is online and accepting access.'),
                  const SizedBox(height: 8),
                  Text('You are all caught up.',
                      style: TextStyle(fontSize: 11, color: _muted(context))),
                ] else
                  for (final notice in _notices())
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _NotificationRow(
                          icon: notice.$1,
                          title: notice.$2,
                          subtitle: notice.$3),
                    ),
              ]),
        ),
      );
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow(
      {required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: const Color(0xFFB55433).withValues(alpha: .12),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 16, color: const Color(0xFF9E482E))),
        const SizedBox(width: 10),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(subtitle,
              style: TextStyle(fontSize: 11, color: _muted(context))),
        ])),
      ]);
}
