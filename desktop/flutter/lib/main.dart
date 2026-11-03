import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/app/aurora_app.dart';
import 'package:flutter_hbb/features/launcher/connection_manager_page.dart';
import 'package:flutter_hbb/features/launcher/installer_page.dart';
import 'package:flutter_hbb/features/session/session_window.dart';
import 'package:flutter_hbb/integration/bridge/app_bootstrap.dart';
import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/boot_config.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/route_coordinator.dart';
import 'package:flutter_hbb/integration/routing/session_tabs_model.dart';
import 'package:flutter_hbb/integration/routing/window_coordinator.dart';
import 'package:flutter_hbb/integration/routing/window_frame_keeper.dart';
import 'package:flutter_hbb/integration/routing/window_frame_store.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bring up the native bridge before the first frame. The result, including
  // failure, is exposed through AppBootstrap so the UI renders real state.
  await AppBootstrap.instance.start(args);

  final config = AppBootstrap.instance.config;
  // A `multi_window` launch is a session window, not another workspace. The
  // desktop_multi_window plugin starts this same executable with the window id
  // and its arguments, so the surface is chosen here.
  if (config != null && config.mode == LaunchMode.subWindow) {
    _installWindowMethodHandler();
    runApp(SessionWindowApp(config: config));
    return;
  }

  _installWindowMethodHandler();
  if (config?.mode == LaunchMode.connectionManager) {
    runApp(const AuroraApp(home: ConnectionManagerPage()));
    return;
  }
  if (config?.mode == LaunchMode.install) {
    runApp(const AuroraApp(home: InstallerPage()));
    return;
  }

  await _restoreMainWindow(
    hide: AppBootstrap.instance.launchHandledByLink,
  );
  runApp(const AuroraApp());
}

/// Put the main window back where it was, before the first frame.
///
/// Restoring after the window is visible would show it jumping. A window with
/// no usable saved frame is left where the platform put it.
Future<void> _restoreMainWindow({bool hide = false}) async {
  if (!isDesktop) return;
  try {
    await windowManager.ensureInitialized();
    final frame = WindowFrameStore.instance.restoreFrame(WindowType.Main);
    if (frame == null) {
      if (hide) await windowManager.hide();
      return;
    }

    final size = frame.size;
    if (size != null) await windowManager.setSize(size);
    final offset = frame.offset;
    if (offset == null) {
      await windowManager.center();
    } else {
      await windowManager.setPosition(offset);
    }
    if (frame.isMaximized ?? false) await windowManager.maximize();
    if (hide) await windowManager.hide();
  } catch (e) {
    debugPrint('failed to restore the main window position: $e');
  }
}

/// Answer calls from other windows.
///
/// Every window must register a handler, including the main one. Without it
/// `DesktopMultiWindow.invokeMethod` fails with "failed to find target
/// window", which is what happens when a second connection to an already-open
/// peer tries to focus its existing window.
void _installWindowMethodHandler() {
  if (!isDesktop) return;
  RouteCoordinator.instance
      .installWindowMethodHandler((call, fromWindowId) async {
    switch (call.method) {
      // Asks whether this window already holds a session for a peer, so the
      // main window can focus it instead of opening another.
      case kWindowEventActiveSession:
        final peerId = call.arguments?.toString() ?? '';
        return SessionWindowRegistry.instance.activate(peerId);
      case kWindowEventShow:
        await SessionWindowRegistry.instance.show();
        return true;
      case kWindowConnect:
        final request = _requestFromWindowCall(call.arguments);
        if (request == null) return false;
        await RouteCoordinator.instance.open(request);
        return true;
      default:
        // "Open connections in tabs" routes a session to an already-open
        // window as one of these events rather than starting a process.
        final tab = SessionTabsModel.tabFromEvent(call.method, call.arguments);
        if (tab != null) {
          SessionWindowRegistry.instance.addTab(tab);
          return true;
        }
        debugPrint('unhandled window method: ${call.method}');
        return null;
    }
  });
}

ConnectionRequest? _requestFromWindowCall(dynamic raw) {
  try {
    final value = raw is String ? jsonDecode(raw) : raw;
    final args = Map<String, dynamic>.from(value as Map);
    final id = args['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final kind = args['isFileTransfer'] == true
        ? ConnectionKind.fileTransfer
        : args['isViewCamera'] == true
            ? ConnectionKind.viewCamera
            : args['isTerminal'] == true
                ? ConnectionKind.terminal
                : args['isRDP'] == true
                    ? ConnectionKind.rdp
                    : args['isTcpTunneling'] == true
                        ? ConnectionKind.portForward
                        : ConnectionKind.remoteDesktop;
    return ConnectionRequest(
      peerId: id,
      kind: kind,
      password: args['password']?.toString(),
      forceRelay: args['forceRelay'] == true,
      isSharedPassword: args['isSharedPassword'] as bool?,
      connToken: args['connToken']?.toString(),
      switchUuid: args['switch_uuid']?.toString(),
    );
  } catch (e) {
    debugPrint('invalid connect-window payload: $e');
    return null;
  }
}

/// Tracks the sessions this window is showing, so calls from the main window
/// can be answered without reaching into the widget tree.
///
/// A window holds several sessions as tabs, so "does this window have peer X"
/// is a question about the tab list rather than about one peer.
class SessionWindowRegistry {
  SessionWindowRegistry._();

  static final SessionWindowRegistry instance = SessionWindowRegistry._();

  SessionTabsModel? _tabs;
  int? _windowId;
  WindowType _type = WindowType.Unknown;

  SessionTabsModel? get tabs => _tabs;

  void register({
    required SessionTabsModel tabs,
    required int? windowId,
    required WindowType type,
  }) {
    _tabs = tabs;
    _windowId = windowId;
    _type = type;
  }

  /// True when this window already holds [peerId], after selecting that tab
  /// and bringing the window to the front.
  bool activate(String peerId) {
    final tabs = _tabs;
    if (tabs == null || !tabs.contains(peerId)) return false;
    tabs.selectPeer(peerId);
    unawaited(show());
    return true;
  }

  /// Open [tab] here, or select it when this window already has that peer.
  ///
  /// This is what makes "open connections in tabs" work: the main window posts
  /// the session to an open window instead of creating another.
  void addTab(SessionTab tab) {
    final tabs = _tabs;
    if (tabs == null) return;
    tabs.add(tab);
    unawaited(show());
  }

  Future<void> show() async {
    final windowId = _windowId;
    if (windowId == null) return;
    try {
      final controller = WindowController.fromWindowId(windowId);
      await controller.show();
    } catch (e) {
      debugPrint('failed to show window $windowId: $e');
    }
  }

  /// Retitle the window for whichever session is in front.
  Future<void> syncTitle() async {
    final windowId = _windowId;
    if (windowId == null || !isDesktop) return;
    final peerId = _tabs?.selected?.peerId ?? '';
    try {
      await WindowController.fromWindowId(windowId)
          .setTitle(WindowCoordinator.titleFor(_type, peerId));
    } catch (e) {
      debugPrint('failed to set the title of window $windowId: $e');
    }
  }

  Future<void> close() async {
    final windowId = _windowId;
    if (windowId == null) return;
    try {
      final controller = WindowController.fromWindowId(windowId);
      await controller.setPreventClose(false);
      await controller.close();
    } catch (e) {
      debugPrint('failed to close window $windowId: $e');
    }
  }
}

/// The app shown in a `multi_window` sub window.
///
/// Holds the sessions the main window routed here, as tabs. Closing the last
/// one closes the window; the main window keeps running.
class SessionWindowApp extends StatefulWidget {
  const SessionWindowApp({super.key, required this.config});

  final BootConfig config;

  @override
  State<SessionWindowApp> createState() => _SessionWindowAppState();
}

class _SessionWindowAppState extends State<SessionWindowApp> {
  late final SessionTabsModel _tabs;

  @override
  void initState() {
    super.initState();
    final config = widget.config;
    final peerId = config.peerId ?? '';
    _tabs = SessionTabsModel(tabs: [
      if (peerId.isNotEmpty)
        SessionTab(
          peerId: peerId,
          kind: _kindOf(config.windowType, config.windowArgs),
          password: config.windowArgs['password'] as String?,
          forceRelay: config.windowArgs['forceRelay'] == true,
          isSharedPassword: config.windowArgs['isSharedPassword'] as bool?,
          connToken: config.windowArgs['connToken']?.toString(),
          switchUuid: config.windowArgs['switch_uuid']?.toString(),
        ),
    ]);
    // The title follows the front tab, so a window with several sessions
    // names the one being looked at.
    _tabs.addListener(_onTabsChanged);
    SessionWindowRegistry.instance.register(
      tabs: _tabs,
      windowId: config.windowId,
      type: config.windowType ?? WindowType.Unknown,
    );
  }

  void _onTabsChanged() =>
      unawaited(SessionWindowRegistry.instance.syncTitle());

  @override
  void dispose() {
    _tabs.removeListener(_onTabsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final type = config.windowType ?? WindowType.Unknown;
    return AuroraApp(
      home: WindowFrameKeeper(
        type: type,
        windowId: config.windowId,
        peerId: config.peerId,
        child: SessionWindow(
          tabs: _tabs,
          onLastTabClosed: () =>
              unawaited(SessionWindowRegistry.instance.close()),
        ),
      ),
      onReady: () async {
        final windowId = config.windowId;
        if (windowId == null || !isDesktop) return;
        final controller = WindowController.fromWindowId(windowId);
        // The window is created hidden so it does not flash empty before the
        // session surface is laid out.
        await SessionWindowRegistry.instance.syncTitle();
        await controller.show();
      },
    );
  }

  /// What kind of session a window was launched for.
  ///
  /// Port forward and RDP share a window type; the payload's RDP flag is what
  /// tells them apart.
  static ConnectionKind _kindOf(WindowType? type, Map<String, dynamic> args) {
    switch (type) {
      case WindowType.FileTransfer:
        return ConnectionKind.fileTransfer;
      case WindowType.Terminal:
        return ConnectionKind.terminal;
      case WindowType.ViewCamera:
        return ConnectionKind.viewCamera;
      case WindowType.PortForward:
        return args['isRDP'] == true
            ? ConnectionKind.rdp
            : ConnectionKind.portForward;
      case WindowType.RemoteDesktop:
      case WindowType.Main:
      case WindowType.Unknown:
      case null:
        return ConnectionKind.remoteDesktop;
    }
  }
}
