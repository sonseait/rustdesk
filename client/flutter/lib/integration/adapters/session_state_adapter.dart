import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// Readiness of the local sharing service, as tracked per window.
enum SvcStatus { notReady, connecting, ready }

/// Window-scoped UI state shared across surfaces.
///
/// Ported from `StateGlobal` in `flutter_legacy/lib/models/state_model.dart`,
/// with the GetX observables replaced by [ChangeNotifier] and [ValueNotifier].
/// This holds transient window state only; nothing here is persisted.
class SessionStateAdapter extends ChangeNotifier {
  SessionStateAdapter._();

  static final SessionStateAdapter instance = SessionStateAdapter._();

  final ValueNotifier<bool> fullscreen = ValueNotifier(false);
  final ValueNotifier<bool> isMaximized = ValueNotifier(false);
  final ValueNotifier<bool> isFocused = ValueNotifier(false);
  final ValueNotifier<bool> showTabBar = ValueNotifier(true);
  final ValueNotifier<bool> showRemoteToolBar = ValueNotifier(false);
  final ValueNotifier<bool> isPortrait = ValueNotifier(false);
  final ValueNotifier<SvcStatus> svcStatus = ValueNotifier(SvcStatus.notReady);
  final ValueNotifier<int> videoConnCount = ValueNotifier(0);
  final ValueNotifier<String> updateUrl = ValueNotifier('');

  int _windowId = kInvalidWindowId;
  bool _isMinimized = false;

  /// Mobile and web only.
  bool isInMainPage = true;

  /// Relative mouse mode per peer. Session-only runtime state, never
  /// persisted to config.
  final Map<String, bool> _relativeMouseMode = {};

  /// Desktop remote toolbar resolution memory, keyed by peer then display.
  final Map<String, Map<int, String?>> _lastResolutionGroupValues = {};

  int get windowId => _windowId;

  bool get isMinimized => _isMinimized;

  bool get isMainWindow => _windowId == kWindowMainId;

  void setWindowId(int id) {
    if (_windowId == id) return;
    _windowId = id;
    notifyListeners();
  }

  void setMinimized(bool value) {
    if (_isMinimized == value) return;
    _isMinimized = value;
    notifyListeners();
  }

  bool relativeMouseModeOf(String peerId) =>
      _relativeMouseMode[peerId] ?? false;

  void setRelativeMouseMode(String peerId, bool enabled) {
    if (_relativeMouseMode[peerId] == enabled) return;
    _relativeMouseMode[peerId] = enabled;
    notifyListeners();
  }

  void clearRelativeMouseMode(String peerId) {
    if (_relativeMouseMode.remove(peerId) != null) notifyListeners();
  }

  void resetLastResolutionGroupValues(String peerId) {
    _lastResolutionGroupValues[peerId] = {};
  }

  void setLastResolutionGroupValue(
      String peerId, int currentDisplay, String? value) {
    (_lastResolutionGroupValues[peerId] ??= {})[currentDisplay] = value;
  }

  String? getLastResolutionGroupValue(String peerId, int currentDisplay) =>
      _lastResolutionGroupValues[peerId]?[currentDisplay];

  /// Drop all state belonging to [peerId] when its session closes.
  void forgetPeer(String peerId) {
    _relativeMouseMode.remove(peerId);
    _lastResolutionGroupValues.remove(peerId);
  }
}

/// Connection kinds, matching the Rust `ConnType` discriminants.
///
/// The integer values cross the FFI boundary in `peerGetSessionsCount`.
enum ConnType {
  defaultConn(0),
  fileTransfer(1),
  portForward(2),
  rdp(3),
  viewCamera(4),
  terminal(5);

  const ConnType(this.value);

  final int value;
}

/// Read-only view of how many sessions the core holds for a peer.
///
/// The session id inventory itself lives on the multi-window channel, not the
/// bridge; [RouteCoordinator] owns that. This adapter answers the one question
/// the core exposes directly: whether a peer already has a live session, which
/// the workspace needs before offering to connect.
class SessionInventoryAdapter {
  const SessionInventoryAdapter();

  static const SessionInventoryAdapter instance = SessionInventoryAdapter();

  /// How many sessions of [connType] exist for [peerId].
  int sessionCount(String peerId,
      {ConnType connType = ConnType.defaultConn}) {
    try {
      return bind.peerGetSessionsCount(
          id: peerId, connType: connType.value);
    } catch (e) {
      debugPrint('failed to read the session count for $peerId: $e');
      return 0;
    }
  }

  /// Whether [peerId] already has a live session of [connType].
  bool hasSession(String peerId,
          {ConnType connType = ConnType.defaultConn}) =>
      sessionCount(peerId, connType: connType) > 0;
}

/// The process-wide window state.
SessionStateAdapter get sessionState => SessionStateAdapter.instance;
