import 'package:flutter/widgets.dart';

import 'package:flutter_hbb/features/session/session_view_model.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';
import 'package:flutter_hbb/integration/session/chat_model.dart';
import 'package:flutter_hbb/integration/session/session_adapter.dart';
import 'package:flutter_hbb/integration/session/port_forward_model.dart';
import 'package:flutter_hbb/integration/session/session_options.dart';

/// An in-memory [SessionViewModel] for widget tests.
///
/// Widget tests have no native bridge, so the real model cannot start a
/// session. This subclass reports whatever stage the test asks for and records
/// the calls the surfaces make.
class FakeSessionViewModel extends SessionViewModel {
  FakeSessionViewModel({
    super.peerId = '847293160',
    this.stageOverride = SessionStage.live,
    this.peerInfoOverride = const PeerInfo(),
    this.promptOverride,
    this.secure = true,
    this.direct = true,
  });

  final SessionStage stageOverride;
  final PeerInfo peerInfoOverride;
  final SessionPrompt? promptOverride;
  final bool secure;
  final bool direct;

  final List<int> displaySwitches = [];
  final List<String> viewStyles = [];
  final List<String> submittedPasswords = [];
  var reconnects = 0;
  var _viewOnly = false;

  @override
  SessionStage get stage => stageOverride;

  @override
  PeerInfo get peerInfo => peerInfoOverride;

  @override
  SessionPrompt? get prompt => promptOverride;

  @override
  bool get isSecure => secure;

  @override
  bool get isDirect => direct;

  @override
  bool get isViewOnly => _viewOnly;

  @override
  bool get canSendInput => !_viewOnly;

  @override
  String get viewStyle => viewStyles.isEmpty ? 'adaptive' : viewStyles.last;

  @override
  Future<void> start({
    String? password,
    bool forceRelay = false,
    bool isSharedPassword = false,
    String? connToken,
    String switchUuid = '',
  }) async {}

  @override
  void updateViewport(Size viewport, {double devicePixelRatio = 1.0}) {}

  @override
  Future<void> switchDisplay(int display) async {
    displaySwitches.add(display);
    notifyListeners();
  }

  @override
  Future<void> setViewStyle(String style) async {
    viewStyles.add(style);
    notifyListeners();
  }

  @override
  void setViewOnly(bool value) {
    _viewOnly = value;
    notifyListeners();
  }

  @override
  Future<void> reconnect({bool forceRelay = false}) async {
    reconnects++;
    notifyListeners();
  }

  @override
  Future<void> submitPassword(String password, {bool remember = false}) async {
    submittedPasswords.add(password);
  }

  /// Chat is backed by a real model with an injected clock; only the send
  /// path would need the bridge, and the tests do not exercise it.
  late final ChatModel _chat = ChatModel(
    sessionId: session.sessionId,
    clock: () => DateTime.utc(2026),
  )
    // The real model forwards chat changes so the toolbar badge rebuilds.
    ..addListener(notifyListeners);

  @override
  ChatModel get chat => _chat;

  @override
  int get unreadChatCount => _chat.unreadCount;

  /// Session switches, recorded in memory: every real call would need the
  /// native bridge.
  late final _options = FakeSessionOptions(sessionId: session.sessionId)
    // The real model forwards option changes so the toolbar rebuilds.
    ..addListener(notifyListeners);

  @override
  SessionOptions get options => _options;

  /// Tunnels, recorded in memory: adding one really would reach the core.
  late final _portForwards = FakePortForwardModel(
    sessionId: session.sessionId,
    peerId: peerId,
  )..addListener(notifyListeners);

  @override
  PortForwardModel get portForwards => _portForwards;

  @override
  Future<void> close() async {}
}

/// In-memory [PortForwardModel] for widget tests.
class FakePortForwardModel extends PortForwardModel {
  FakePortForwardModel({required super.sessionId, required super.peerId});

  final List<PortForward> rules = [];
  final List<int> removed = [];
  var rdpOpened = 0;

  @override
  List<PortForward> get forwards => List.unmodifiable(rules);

  @override
  bool get isEmpty => rules.isEmpty;

  @override
  Object? get error => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> add({
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    rules.add(PortForward(
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
    ));
    notifyListeners();
  }

  @override
  Future<void> remove(int localPort) async {
    removed.add(localPort);
    rules.removeWhere((r) => r.localPort == localPort);
    notifyListeners();
  }

  @override
  Future<void> openRdp() async {
    rdpOpened++;
  }
}

/// In-memory [SessionOptions] that records toggles instead of calling the core.
class FakeSessionOptions extends SessionOptions {
  FakeSessionOptions({required super.sessionId});

  final Map<SessionToggle, bool> values = {};
  final List<SessionToggle> toggled = [];
  final List<String> qualities = [];
  bool recording = false;

  @override
  bool isEnabled(SessionToggle toggle) => values[toggle] ?? false;

  @override
  bool get isRecording => recording;

  @override
  void refresh() {}

  @override
  Future<void> toggle(SessionToggle option) async {
    toggled.add(option);
    values[option] = !isEnabled(option);
    notifyListeners();
  }

  @override
  Future<void> setRecording(bool start) async {
    recording = start;
    notifyListeners();
  }

  @override
  Future<void> setImageQuality(String value) async {
    qualities.add(value);
    notifyListeners();
  }
}
