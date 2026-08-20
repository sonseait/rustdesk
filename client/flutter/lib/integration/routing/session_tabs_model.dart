import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';

/// One session open in a window.
@immutable
class SessionTab {
  const SessionTab({
    required this.peerId,
    required this.kind,
    this.password,
    this.forceRelay = false,
    this.isSharedPassword,
    this.connToken,
    this.switchUuid,
  });

  /// A tab for the session [request] asked for.
  SessionTab.of(ConnectionRequest request)
      : peerId = request.peerId,
        kind = request.kind,
        password = request.password,
        forceRelay = request.forceRelay,
        isSharedPassword = request.isSharedPassword,
        connToken = request.connToken,
        switchUuid = request.switchUuid;

  final String peerId;
  final ConnectionKind kind;
  final String? password;
  final bool forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final String? switchUuid;

  /// What identifies this tab within a window.
  ///
  /// The peer id: a window holds one session per peer, which is what lets a
  /// second connection to an open peer focus the existing tab instead of
  /// opening a duplicate.
  String get key => peerId;

  @override
  bool operator ==(Object other) =>
      other is SessionTab && other.peerId == peerId && other.kind == kind;

  @override
  int get hashCode => Object.hash(peerId, kind);
}

/// The sessions open in one window, and which is in front.
///
/// A desktop window holds several sessions as tabs. `WindowCoordinator` posts
/// the window's `new_*` event when a session should join an open window rather
/// than get its own; this model is what receives it.
///
/// Closing is asked for rather than done: a live session may need to be
/// confirmed first, so a caller decides and then calls [close].
class SessionTabsModel extends ChangeNotifier {
  SessionTabsModel({List<SessionTab> tabs = const [], int selected = 0})
      : _tabs = [...tabs],
        _selected = tabs.isEmpty ? 0 : selected.clamp(0, tabs.length - 1);

  final List<SessionTab> _tabs;
  int _selected;

  List<SessionTab> get tabs => List.unmodifiable(_tabs);

  int get length => _tabs.length;

  bool get isEmpty => _tabs.isEmpty;

  /// The index of the tab in front. Zero when there are no tabs.
  int get selectedIndex => _selected;

  SessionTab? get selected =>
      _tabs.isEmpty ? null : _tabs[_selected.clamp(0, _tabs.length - 1)];

  int indexOf(String peerId) =>
      _tabs.indexWhere((tab) => tab.peerId == peerId);

  bool contains(String peerId) => indexOf(peerId) >= 0;

  /// Add [tab], or bring the existing session for that peer to the front.
  ///
  /// Returns true when a tab was added. Reconnecting to an open peer must not
  /// open a second session against it, so an existing one is selected instead.
  bool add(SessionTab tab) {
    final existing = indexOf(tab.peerId);
    if (existing >= 0) {
      select(existing);
      return false;
    }
    _tabs.add(tab);
    _selected = _tabs.length - 1;
    notifyListeners();
    return true;
  }

  void select(int index) {
    if (_tabs.isEmpty) return;
    final next = index.clamp(0, _tabs.length - 1);
    if (next == _selected) return;
    _selected = next;
    notifyListeners();
  }

  void selectPeer(String peerId) {
    final index = indexOf(peerId);
    if (index >= 0) select(index);
  }

  /// Close the tab for [peerId]. Returns true when one was removed.
  ///
  /// The tab to the left takes over, so closing the last tab does not leave
  /// the selection past the end.
  bool close(String peerId) {
    final index = indexOf(peerId);
    if (index < 0) return false;
    _tabs.removeAt(index);
    if (_tabs.isEmpty) {
      _selected = 0;
    } else if (_selected >= index) {
      _selected = (_selected - 1).clamp(0, _tabs.length - 1);
    }
    notifyListeners();
    return true;
  }

  void closeAll() {
    if (_tabs.isEmpty) return;
    _tabs.clear();
    _selected = 0;
    notifyListeners();
  }

  /// The tab a window event asked to open, or null when the payload is not one
  /// this window can act on.
  ///
  /// The payload is the JSON `WindowCoordinator` sends, so the keys here are
  /// the existing multi-window contract.
  static SessionTab? tabFromEvent(String method, dynamic arguments) {
    final kind = _kindOf(method);
    if (kind == null) return null;
    try {
      final raw = arguments is String ? jsonDecode(arguments) : arguments;
      if (raw is! Map) return null;
      final peerId = raw['id']?.toString() ?? '';
      if (peerId.isEmpty) return null;
      return SessionTab(
        peerId: peerId,
        // A port-forward payload carries the RDP flag rather than its own
        // event, matching how the request was encoded.
        kind: kind == ConnectionKind.portForward && raw['isRDP'] == true
            ? ConnectionKind.rdp
            : kind,
        password: raw['password']?.toString(),
        forceRelay: raw['forceRelay'] == true,
        isSharedPassword: raw['isSharedPassword'] as bool?,
        connToken: raw['connToken']?.toString(),
        switchUuid: raw['switch_uuid']?.toString(),
      );
    } catch (e) {
      debugPrint('failed to read a window event payload: $e');
      return null;
    }
  }

  static ConnectionKind? _kindOf(String method) {
    switch (method) {
      case kWindowEventNewRemoteDesktop:
        return ConnectionKind.remoteDesktop;
      case kWindowEventNewFileTransfer:
        return ConnectionKind.fileTransfer;
      case kWindowEventNewViewCamera:
        return ConnectionKind.viewCamera;
      case kWindowEventNewPortForward:
        return ConnectionKind.portForward;
      case kWindowEventNewTerminal:
        return ConnectionKind.terminal;
      default:
        return null;
    }
  }
}
