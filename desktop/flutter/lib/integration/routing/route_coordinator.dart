import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/boot_config.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/window_coordinator.dart';

/// A request that arrived from outside the current surface.
typedef ConnectionRequestHandler = Future<void> Function(
    ConnectionRequest request);

/// Called when something asked for the main window to be shown.
typedef ShowMainWindowHandler = Future<void> Function();

/// Routes inbound connection and window events to the active UI.
///
/// This is the seam the Aurora surfaces attach to. It accepts the existing
/// events — launch arguments, `rustdesk://` links, and multi-window method
/// calls — and hands them to whichever surface is mounted. Milestone 0 wires
/// the plumbing; the handlers are supplied by the workspace and session pages
/// as they migrate.
///
/// Events that arrive before a handler is attached are queued rather than
/// dropped, so a cold-start deep link still opens once the UI is ready.
class RouteCoordinator {
  RouteCoordinator({WindowCoordinator? windowCoordinator})
      : _windows = windowCoordinator ?? WindowCoordinator.instance;

  static final RouteCoordinator instance = RouteCoordinator();

  final WindowCoordinator _windows;

  final List<ConnectionRequest> _pendingRequests = [];
  bool _pendingShowMainWindow = false;

  ConnectionRequestHandler? _onConnectionRequest;
  ShowMainWindowHandler? _onShowMainWindow;

  /// Requests received before a handler was attached.
  @visibleForTesting
  List<ConnectionRequest> get pendingRequests =>
      List.unmodifiable(_pendingRequests);

  @visibleForTesting
  bool get pendingShowMainWindow => _pendingShowMainWindow;

  /// Attach the active surface. Any queued events are delivered immediately.
  Future<void> attach({
    ConnectionRequestHandler? onConnectionRequest,
    ShowMainWindowHandler? onShowMainWindow,
  }) async {
    _onConnectionRequest = onConnectionRequest ?? _onConnectionRequest;
    _onShowMainWindow = onShowMainWindow ?? _onShowMainWindow;
    await _drain();
  }

  void detach() {
    _onConnectionRequest = null;
    _onShowMainWindow = null;
  }

  /// Handle the arguments the process was launched with.
  ///
  /// Returns true when the launch was consumed by a link, which the desktop
  /// shell uses to decide whether to keep the main window hidden.
  Future<bool> handleLaunch(BootConfig config) async {
    if (!config.isMainWindow) return false;
    var args = config.args;
    // `rustdesk <uri>` — the first argument may itself be a link.
    if (args.isNotEmpty && args.first.startsWith(_uriPrefix())) {
      final uri = Uri.tryParse(args.first);
      final converted = uri == null ? null : uriToCmdArgs(uri);
      if (converted != null) args = converted;
    }
    final result = parseCmdArgs(args);
    return _dispatch(result);
  }

  /// Handle a `rustdesk://` link delivered while running.
  Future<bool> handleUri(Uri uri) => _dispatch(parseUriLink(uri));

  Future<bool> _dispatch(UriLinkResult result) async {
    if (result.request != null) {
      await _deliverRequest(result.request!);
      return true;
    }
    if (result.showMainWindow) {
      await _deliverShowMainWindow();
      return true;
    }
    return false;
  }

  Future<void> _deliverRequest(ConnectionRequest request) async {
    if (request.isTerminalAdmin) {
      // The core reads this env var when the terminal session starts.
      bind.mainSetEnv(key: 'IS_TERMINAL_ADMIN', value: 'Y');
    }
    final handler = _onConnectionRequest;
    if (handler == null) {
      _pendingRequests.add(request);
      return;
    }
    await handler(request);
  }

  Future<void> _deliverShowMainWindow() async {
    final handler = _onShowMainWindow;
    if (handler == null) {
      _pendingShowMainWindow = true;
      return;
    }
    await handler();
  }

  Future<void> _drain() async {
    if (_pendingShowMainWindow && _onShowMainWindow != null) {
      _pendingShowMainWindow = false;
      await _onShowMainWindow!();
    }
    if (_pendingRequests.isEmpty || _onConnectionRequest == null) return;
    final queued = List.of(_pendingRequests);
    _pendingRequests.clear();
    for (final request in queued) {
      await _onConnectionRequest!(request);
    }
  }

  /// Open a session in the appropriate window.
  Future<WindowCallResult> open(ConnectionRequest request) =>
      _windows.open(request);

  /// Install the multi-window method handler.
  ///
  /// [onCall] receives calls other windows make to this one. Milestone 0
  /// forwards them verbatim; the surfaces that answer them (tab pages, session
  /// screens) attach their own handling as they migrate.
  void installWindowMethodHandler(
      Future<dynamic> Function(MethodCall call, int fromWindowId) onCall) {
    if (!isDesktop) return;
    _windows.setMethodHandler(onCall);
  }

  String _uriPrefix() {
    try {
      return bind.mainUriPrefixSync();
    } catch (e) {
      debugPrint('failed to read the uri prefix: $e');
      return 'rustdesk://';
    }
  }

  /// Test-only: clear queued events and handlers.
  @visibleForTesting
  void resetForTest() {
    _pendingRequests.clear();
    _pendingShowMainWindow = false;
    _onConnectionRequest = null;
    _onShowMainWindow = null;
  }
}

/// The process-wide route coordinator.
RouteCoordinator get routes => RouteCoordinator.instance;

/// Convenience: the window types a sub window may be launched as.
const List<WindowType> kSessionWindowTypes = [
  WindowType.RemoteDesktop,
  WindowType.FileTransfer,
  WindowType.ViewCamera,
  WindowType.PortForward,
  WindowType.Terminal,
];
