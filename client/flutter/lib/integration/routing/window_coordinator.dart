import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/window_frame_store.dart';

/// The window a call was routed to, and whatever it returned.
@immutable
class WindowCallResult {
  const WindowCallResult(this.windowId, this.result);

  final int windowId;
  final dynamic result;

  bool get isValid => windowId != kInvalidWindowId;
}

/// Owns sub-window creation and the multi-window method channel.
///
/// Ported from `RustDeskMultiWindowManager` in
/// `flutter_legacy/lib/utils/multi_window_manager.dart`. The method names,
/// argument JSON, and window-reuse rules are the existing contract: the legacy
/// UI and Aurora must agree on them for a session to open in the right place.
class WindowCoordinator {
  WindowCoordinator({OptionRepository? optionRepository, WindowFrameStore? frames})
      : _options = optionRepository ?? OptionRepository.instance,
        _frames = frames ?? WindowFrameStore.instance;

  static final WindowCoordinator instance = WindowCoordinator();

  final OptionRepository _options;
  final WindowFrameStore _frames;

  /// The peer each sub window was opened for, so its frame can be saved
  /// against that peer when it closes.
  final Map<int, String> _windowPeers = {};

  final Set<int> _activeWindows = {};
  final Set<int> _inactiveWindows = {};
  final List<AsyncCallback> _activeWindowCallbacks = [];

  final List<int> _remoteDesktopWindows = [];
  final List<int> _fileTransferWindows = [];
  final List<int> _viewCameraWindows = [];
  final List<int> _portForwardWindows = [];
  final List<int> _terminalWindows = [];

  Set<int> get activeWindows => Set.unmodifiable(_activeWindows);

  /// Open the session described by [request], reusing a window when the
  /// existing rules allow it.
  Future<WindowCallResult> open(ConnectionRequest request) async {
    final type = request.kind.windowType;
    final windows = windowsOf(type);

    final params = <String, dynamic>{
      'type': type.index,
      'id': request.peerId,
      'password': request.password,
      'forceRelay': request.forceRelay,
    };
    if (request.switchUuid != null) {
      params['switch_uuid'] = request.switchUuid;
    }
    if (request.kind == ConnectionKind.rdp ||
        request.kind == ConnectionKind.portForward) {
      params['isRDP'] = request.isRDP;
    }
    if (request.isSharedPassword != null) {
      params['isSharedPassword'] = request.isSharedPassword;
    }
    if (request.connToken != null) {
      params['connToken'] = request.connToken;
    }
    final msg = jsonEncode(params);

    // Terminals always get a fresh window: invoking new_terminal on an
    // inactive window raises MissingPluginException.
    if (request.kind == ConnectionKind.terminal) {
      // Most recently used windows first — likelier to hold a live session.
      for (final windowId in _terminalWindows.reversed) {
        if (await _activateSession(windowId, request.peerId)) {
          return WindowCallResult(windowId, null);
        }
      }
      final windowId = await _createWindow(type, msg, peerId: request.peerId);
      return WindowCallResult(windowId, null);
    }

    // A separate window for file transfer is not supported, so everything but
    // remote desktop opens in tabs.
    final openInTabs = type != WindowType.RemoteDesktop ||
        _options.getLocalBool(kOptionOpenNewConnInTabs);

    if (windows.length > 1 || !openInTabs) {
      for (final windowId in windows) {
        if (await _activateSession(windowId, request.peerId)) {
          return WindowCallResult(windowId, null);
        }
      }
    }

    if (openInTabs && windows.isNotEmpty) {
      return call(type, request.kind.newWindowEvent, msg);
    }

    // Reuse a hidden window of the right type before creating another.
    for (final windowId in windows) {
      if (!_inactiveWindows.contains(windowId)) continue;
      await DesktopMultiWindow.invokeMethod(
          windowId, request.kind.newWindowEvent, msg);
      if (request.kind != ConnectionKind.remoteDesktop) {
        await WindowController.fromWindowId(windowId).show();
      }
      await registerActiveWindow(windowId);
      return WindowCallResult(windowId, null);
    }

    final windowId = await _createWindow(type, msg, peerId: request.peerId);
    return WindowCallResult(windowId, null);
  }

  Future<bool> _activateSession(int windowId, String peerId) async {
    try {
      final res = await DesktopMultiWindow.invokeMethod(
          windowId, kWindowEventActiveSession, peerId);
      return res == true;
    } catch (e) {
      debugPrint('failed to activate a session on window $windowId: $e');
      return false;
    }
  }

  Future<int> _createWindow(WindowType type, String msg,
      {String peerId = ''}) async {
    final controller = await DesktopMultiWindow.createWindow(msg);
    final windowId = controller.windowId;
    if (peerId.isNotEmpty) _windowPeers[windowId] = peerId;

    // Where this window was last time, if it is somewhere sensible.
    final frame = _frames.restoreFrame(type,
        windowId: windowId, peerId: peerId.isEmpty ? null : peerId);
    final size = frame?.size ?? const Size(1280, 720);
    final offset = frame?.offset;
    if (offset == null) {
      // No usable saved position: let the platform centre it rather than
      // opening the window somewhere off-screen.
      await controller.setFrame(Offset.zero & size);
      await controller.center();
    } else {
      await controller.setFrame(offset & size);
    }
    await controller.setTitle(titleFor(type, peerId));
    // The sub window is created hidden. Without this it never appears, and
    // the session runs invisibly.
    await controller.show();
    if (frame?.isMaximized ?? false) {
      try {
        await controller.maximize();
      } catch (e) {
        debugPrint('failed to maximize window $windowId: $e');
      }
    }
    await registerActiveWindow(windowId);
    windowsOf(type).add(windowId);
    return windowId;
  }

  /// The title bar text for a window, so a user with several open windows can
  /// tell which peer and tool each one is.
  static String titleFor(WindowType type, String peerId) {
    final tool = switch (type) {
      WindowType.RemoteDesktop => 'Remote desktop',
      WindowType.FileTransfer => 'File transfer',
      WindowType.ViewCamera => 'Camera',
      WindowType.PortForward => 'Port forward',
      WindowType.Terminal => 'Terminal',
      WindowType.Main || WindowType.Unknown => '',
    };
    if (tool.isEmpty) return 'RustDesk';
    if (peerId.isEmpty) return 'RustDesk · $tool';
    return 'RustDesk · $tool · $peerId';
  }

  /// Remember the frame a window closed with.
  ///
  /// [peerId] defaults to whichever peer this window was opened for, so a
  /// session window reopens where that peer left it.
  Future<void> saveFrame(
    WindowType type,
    WindowFrame frame, {
    int? windowId,
    String? peerId,
  }) async {
    await _frames.saveFrame(type, frame);
    final peer = peerId ?? (windowId == null ? null : _windowPeers[windowId]);
    if (peer == null || peer.isEmpty) return;
    _frames.savePeerFrame(
        type, peer, _frames.peerFrameToSave(type, peer, frame));
  }

  /// The peer a sub window was opened for, if it is still tracked.
  String? peerOf(int windowId) => _windowPeers[windowId];

  /// Invoke [methodName] on a window of [type], preferring an active one.
  Future<WindowCallResult> call(
      WindowType type, String methodName, dynamic args) async {
    final windows = windowsOf(type);
    if (windows.isEmpty) {
      return const WindowCallResult(kInvalidWindowId, null);
    }
    for (final windowId in windows) {
      if (_activeWindows.contains(windowId)) {
        final res =
            await DesktopMultiWindow.invokeMethod(windowId, methodName, args);
        return WindowCallResult(windowId, res);
      }
    }
    final res =
        await DesktopMultiWindow.invokeMethod(windows.first, methodName, args);
    return WindowCallResult(windows.first, res);
  }

  /// The window ids tracked for [type]. Mutable by design: the legacy manager
  /// tracks membership by appending to these lists.
  List<int> windowsOf(WindowType type) {
    switch (type) {
      case WindowType.Main:
        return [kMainWindowId];
      case WindowType.RemoteDesktop:
        return _remoteDesktopWindows;
      case WindowType.FileTransfer:
        return _fileTransferWindows;
      case WindowType.ViewCamera:
        return _viewCameraWindows;
      case WindowType.PortForward:
        return _portForwardWindows;
      case WindowType.Terminal:
        return _terminalWindows;
      case WindowType.Unknown:
        return [];
    }
  }

  void clearWindowType(WindowType type) {
    if (type == WindowType.Main || type == WindowType.Unknown) return;
    windowsOf(type).clear();
  }

  /// Install the handler for calls arriving from other windows.
  void setMethodHandler(
      Future<dynamic> Function(MethodCall call, int fromWindowId)? handler) {
    DesktopMultiWindow.setMethodHandler(handler);
  }

  Future<List<int>> getAllSubWindowIds() async {
    try {
      return await DesktopMultiWindow.getAllSubWindowIds();
    } catch (e) {
      if (e is AssertionError) return [];
      rethrow;
    }
  }

  Future<void> registerActiveWindow(int windowId) async {
    _activeWindows.add(windowId);
    _inactiveWindows.remove(windowId);
    await _notifyActiveWindow();
  }

  /// Mark a window inactive.
  ///
  /// Only the main window may call this. Other windows must post
  /// [kWindowEventHide] to the main window instead.
  Future<void> unregisterActiveWindow(int windowId) async {
    _activeWindows.remove(windowId);
    if (windowId != kMainWindowId) _inactiveWindows.add(windowId);
    await _notifyActiveWindow();
  }

  void registerActiveWindowListener(AsyncCallback callback) {
    _activeWindowCallbacks.add(callback);
  }

  void unregisterActiveWindowListener(AsyncCallback callback) {
    _activeWindowCallbacks.remove(callback);
  }

  Future<void> _notifyActiveWindow() async {
    for (final callback in List.of(_activeWindowCallbacks)) {
      await callback();
    }
  }

  /// Close every sub window. The main window is left to the shell.
  Future<void> closeAllSubWindows() async {
    for (final type in WindowType.values) {
      if (type == WindowType.Main || type == WindowType.Unknown) continue;
      await _closeWindows(type);
    }
  }

  Future<void> _closeWindows(WindowType type) async {
    final windows = List.of(windowsOf(type));
    for (final windowId in windows) {
      try {
        await WindowController.fromWindowId(windowId).setPreventClose(false);
        await WindowController.fromWindowId(windowId).close();
        _activeWindows.remove(windowId);
        _inactiveWindows.remove(windowId);
        _windowPeers.remove(windowId);
      } catch (e) {
        debugPrint('failed to close window $windowId: $e');
        return;
      }
    }
    clearWindowType(type);
  }

  /// Test-only: reset tracked window state.
  @visibleForTesting
  void resetForTest() {
    _activeWindows.clear();
    _inactiveWindows.clear();
    _activeWindowCallbacks.clear();
    _windowPeers.clear();
    for (final type in WindowType.values) {
      if (type == WindowType.Main || type == WindowType.Unknown) continue;
      windowsOf(type).clear();
    }
  }
}

/// The process-wide window coordinator.
WindowCoordinator get windows => WindowCoordinator.instance;
