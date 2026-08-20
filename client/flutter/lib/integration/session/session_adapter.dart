import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

/// Where a session is in its lifecycle.
enum SessionPhase {
  /// Created but not started.
  idle,

  /// Connecting, or reconnecting after a drop.
  connecting,

  /// Connected; peer info has arrived and frames may be flowing.
  connected,

  /// The peer or the core ended the session.
  closed,

  /// Connecting failed.
  failed,
}

/// A prompt from the core that needs the user to act.
///
/// The core drives every credential and confirmation flow through `msgbox`;
/// the UI must render these rather than inventing its own.
@immutable
class SessionPrompt {
  const SessionPrompt({
    required this.type,
    required this.title,
    required this.text,
    this.link = '',
    this.hasRetry = false,
  });

  factory SessionPrompt.fromEvent(Map<String, dynamic> evt) => SessionPrompt(
        type: evt['type']?.toString() ?? '',
        title: evt['title']?.toString() ?? '',
        text: evt['text']?.toString() ?? '',
        link: evt['link']?.toString() ?? '',
        hasRetry: evt['hasRetry'] == 'true',
      );

  final String type;
  final String title;
  final String text;
  final String link;
  final bool hasRetry;

  /// The core asks for a password, a 2FA code, or OS credentials.
  bool get needsCredentials => const {
        'input-password',
        're-input-password',
        'input-2fa',
        'session-login',
        'session-re-login',
        'session-login-password',
        'terminal-admin-login',
        'terminal-admin-login-password',
      }.contains(type);

  bool get isError => type == 'error' || type.contains('error');

  /// The peer is restarting; the session will reconnect itself.
  bool get isRestarting => type == 'restarting' || type == 'restarting-show';

  @override
  String toString() => 'SessionPrompt($type, $title)';
}

/// One live remote session.
///
/// Ported from the session half of `FFI` in
/// `flutter_legacy/lib/models/model.dart`. Owns the session id, the Rust event
/// stream, peer info, permissions and lifecycle. Rendering, canvas geometry and
/// input live in their own models so this stays the single source of truth for
/// "is this session up, and what is it allowed to do".
///
/// Each instance owns exactly one core session and must be [close]d, or the
/// core leaks it.
class SessionAdapter extends ChangeNotifier {
  SessionAdapter({
    required this.peerId,
    this.kind = ConnectionKind.remoteDesktop,
    UuidValue? sessionId,
    RustdeskImpl? bindOverride,
  })  : sessionId = sessionId ?? const Uuid().v4obj(),
        _bindOverride = bindOverride;

  final String peerId;
  final ConnectionKind kind;

  /// Identifies this session to the core for its whole lifetime.
  final UuidValue sessionId;

  final RustdeskImpl? _bindOverride;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  StreamSubscription<EventToUI>? _subscription;
  SessionPhase _phase = SessionPhase.idle;
  PeerInfo _peerInfo = const PeerInfo();
  SessionPermissions _permissions = const SessionPermissions.empty();
  SessionPrompt? _prompt;
  Object? _error;
  bool _closed = false;
  bool _secure = false;
  bool _direct = false;
  bool _waitingForFirstFrame = true;

  /// Fired when the core reports a new video frame is ready for [display].
  /// The texture model listens to this.
  void Function(int display, bool gpuTexture)? onTextureFrame;

  /// Fired when raw RGBA is ready instead of a texture.
  void Function(int display, Uint8List rgba)? onRgbaFrame;

  /// Fired for every decoded event, for models that need the raw stream.
  void Function(Map<String, dynamic> event)? onEvent;

  SessionPhase get phase => _phase;

  PeerInfo get peerInfo => _peerInfo;

  SessionPermissions get permissions => _permissions;

  /// The current prompt, or null when nothing needs the user.
  SessionPrompt? get prompt => _prompt;

  Object? get error => _error;

  bool get isClosed => _closed;

  /// End-to-end encrypted.
  bool get isSecure => _secure;

  /// Peer-to-peer rather than relayed.
  bool get isDirect => _direct;

  /// True until the first frame arrives, so the UI can show "connecting"
  /// rather than a black canvas.
  bool get isWaitingForFirstFrame => _waitingForFirstFrame;

  bool get isConnected => _phase == SessionPhase.connected;

  int get currentDisplay => _peerInfo.currentDisplay;

  /// Create the session in the core and begin listening.
  ///
  /// [password], [forceRelay] and friends come from the connection request.
  /// Returns false when the core refused to create the session.
  Future<bool> start({
    String? password,
    bool isSharedPassword = false,
    String switchUuid = '',
    bool forceRelay = false,
    String? connToken,
  }) async {
    if (_phase != SessionPhase.idle) return isConnected;
    _setPhase(SessionPhase.connecting);

    try {
      final addResult = _bind.sessionAddSync(
        sessionId: sessionId,
        id: peerId,
        isFileTransfer: kind == ConnectionKind.fileTransfer,
        isViewCamera: kind == ConnectionKind.viewCamera,
        isPortForward:
            kind == ConnectionKind.portForward || kind == ConnectionKind.rdp,
        isRdp: kind == ConnectionKind.rdp,
        isTerminal: kind == ConnectionKind.terminal,
        switchUuid: switchUuid,
        forceRelay: forceRelay,
        password: password ?? '',
        isSharedPassword: isSharedPassword,
        connToken: connToken,
      );
      // A non-empty result is the core's error message.
      if (addResult.isNotEmpty) {
        _fail('failed to add session: $addResult');
        return false;
      }

      final stream = _bind.sessionStart(sessionId: sessionId, id: peerId);
      _subscription = stream.listen(
        _onMessage,
        onError: (Object e) {
          debugPrint('session stream error for $peerId: $e');
          _fail(e);
        },
        onDone: () {
          if (!_closed) _setPhase(SessionPhase.closed);
        },
      );
      return true;
    } catch (e, s) {
      debugPrint('failed to start the session for $peerId: $e');
      debugPrintStack(stackTrace: s);
      _fail(e);
      return false;
    }
  }

  void _onMessage(EventToUI message) {
    if (_closed) return;
    if (message is EventToUI_Event) {
      final raw = message.field0;
      if (raw == 'close') {
        _closed = true;
        _setPhase(SessionPhase.closed);
        return;
      }
      Map<String, dynamic>? event;
      try {
        event = json.decode(raw) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('failed to decode a session event: $e');
        return;
      }
      _handleEvent(event);
    } else if (message is EventToUI_Texture) {
      _markFirstFrame();
      onTextureFrame?.call(message.field0, message.field1);
    } else if (message is EventToUI_Rgba) {
      _handleRgba(message.field0);
    }
  }

  /// Pull one RGBA frame out of the core.
  ///
  /// The buffer must be consumed or explicitly skipped with `nextRgba`, or the
  /// core stalls waiting for the UI to catch up.
  void _handleRgba(int display) {
    final size = platformFFI.getRgbaSize(sessionId, display);
    if (size == 0) {
      platformFFI.nextRgba(sessionId, display);
      return;
    }
    final rgba = platformFFI.getRgba(sessionId, display, size);
    if (rgba == null) {
      platformFFI.nextRgba(sessionId, display);
      return;
    }
    _markFirstFrame();
    onRgbaFrame?.call(display, rgba);
  }

  void _markFirstFrame() {
    if (!_waitingForFirstFrame) return;
    _waitingForFirstFrame = false;
    notifyListeners();
  }

  void _handleEvent(Map<String, dynamic> event) {
    final name = event['name'];
    switch (name) {
      case 'peer_info':
        _peerInfo = PeerInfo.fromEvent(event);
        _setPhase(SessionPhase.connected);
        break;
      case 'sync_peer_info':
        _handleSyncPeerInfo(event);
        break;
      case 'connection_ready':
        _secure = event['secure'] == 'true';
        _direct = event['direct'] == 'true';
        notifyListeners();
        break;
      case 'permissions':
        _handlePermissions(event);
        break;
      case 'switch_display':
        _handleSwitchDisplay(event);
        break;
      case 'msgbox':
        _handlePrompt(event);
        break;
      case 'close':
        _closed = true;
        _setPhase(SessionPhase.closed);
        break;
      default:
        break;
    }
    onEvent?.call(event);
  }

  void _handlePermissions(Map<String, dynamic> event) {
    final raw = event['permissions'];
    if (raw is! String || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _permissions = _permissions.merge({
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value == true || entry.value == 'true',
      });
      notifyListeners();
    } catch (e) {
      debugPrint('failed to decode permissions: $e');
    }
  }

  /// Apply a `sync_peer_info` update.
  ///
  /// The displays arrive as a real JSON array here, unlike `peer_info` where
  /// they are a string. Handling only the string form silently ignored every
  /// geometry update, which left frames being decoded at a stale size.
  void _handleSyncPeerInfo(Map<String, dynamic> event) {
    final displays = _decodeDisplays(event['displays']);
    if (displays == null) return;
    _peerInfo = _peerInfo.copyWith(displays: displays);
    notifyListeners();
  }

  List<RemoteDisplay>? _decodeDisplays(dynamic raw) {
    try {
      final List<dynamic> list;
      if (raw is List) {
        list = raw;
      } else if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return null;
        list = decoded;
      } else {
        return null;
      }
      return [
        for (final d in list)
          if (d is Map<String, dynamic>) RemoteDisplay.fromJson(d)
      ];
    } catch (e) {
      debugPrint('failed to decode displays: $e');
      return null;
    }
  }

  void _handleSwitchDisplay(Map<String, dynamic> event) {
    final display = int.tryParse('${event['display']}');
    if (display == null) return;

    final displays = List<RemoteDisplay>.of(_peerInfo.displays);
    final updated = RemoteDisplay(
      x: double.tryParse('${event['x']}') ?? 0,
      y: double.tryParse('${event['y']}') ?? 0,
      width: int.tryParse('${event['width']}') ??
          (display < displays.length ? displays[display].width : 0),
      height: int.tryParse('${event['height']}') ??
          (display < displays.length ? displays[display].height : 0),
      cursorEmbedded: int.tryParse('${event['cursor_embedded']}') == 1,
      originalWidth:
          int.tryParse('${event['original_width']}') ?? kInvalidResolutionValue,
      originalHeight: int.tryParse('${event['original_height']}') ??
          kInvalidResolutionValue,
    );

    if (display < displays.length) {
      displays[display] = updated;
    } else if (display == displays.length) {
      displays.add(updated);
    }

    _peerInfo = _peerInfo.copyWith(
      // A multi-UI-session peer keeps its own current display; the event only
      // updates that display's geometry.
      currentDisplay:
          _peerInfo.isSupportMultiUiSession ? null : display,
      displays: displays,
    );
    notifyListeners();
  }

  void _handlePrompt(Map<String, dynamic> event) {
    final prompt = SessionPrompt.fromEvent(event);
    _prompt = prompt;
    // A restart is a reconnect, not a failure: the core drives it and the
    // session comes back on its own.
    if (prompt.isRestarting) {
      _permissions = const SessionPermissions.empty();
      _setPhase(SessionPhase.connecting);
      return;
    }
    if (prompt.isError) {
      _error = prompt.text;
      _setPhase(SessionPhase.failed);
      return;
    }
    notifyListeners();
  }

  /// Clear the current prompt once the UI has handled it.
  void dismissPrompt() {
    if (_prompt == null) return;
    _prompt = null;
    notifyListeners();
  }

  /// Answer an `input-password` / `re-input-password` prompt.
  Future<void> submitPassword(String password, {bool remember = false}) async {
    await _bind.sessionLogin(
      sessionId: sessionId,
      osUsername: '',
      osPassword: '',
      password: password,
      remember: remember,
    );
    dismissPrompt();
  }

  /// Answer a `session-login` / OS credential prompt.
  Future<void> submitOsLogin(
    String username,
    String osPassword, {
    String password = '',
    bool remember = false,
  }) async {
    await _bind.sessionLogin(
      sessionId: sessionId,
      osUsername: username,
      osPassword: osPassword,
      password: password,
      remember: remember,
    );
    dismissPrompt();
  }

  /// Answer an `input-2fa` prompt.
  Future<void> submitTwoFactor(String code,
      {bool trustThisDevice = false}) async {
    await _bind.sessionSend2Fa(
      sessionId: sessionId,
      code: code,
      trustThisDevice: trustThisDevice,
    );
    dismissPrompt();
  }

  /// Reconnect after a drop or an explicit request.
  Future<void> reconnect({bool forceRelay = false}) async {
    if (_closed) return;
    _error = null;
    _waitingForFirstFrame = true;
    _setPhase(SessionPhase.connecting);
    await _bind.sessionReconnect(
        sessionId: sessionId, forceRelay: forceRelay);
  }

  /// Show a different display, or [kAllDisplayValue] for every one.
  Future<void> switchDisplay(int display) async {
    if (_closed) return;
    await _bind.sessionSwitchDisplay(
      isDesktop: isDesktop,
      sessionId: sessionId,
      value: Int32List.fromList([display]),
    );
    _peerInfo = _peerInfo.copyWith(currentDisplay: display);
    notifyListeners();
  }

  void _setPhase(SessionPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    notifyListeners();
  }

  void _fail(Object error) {
    _error = error;
    _setPhase(SessionPhase.failed);
  }

  /// Close the core session and release the stream.
  ///
  /// Safe to call more than once. Not calling it leaks a session in the core,
  /// which is why the session page closes in dispose.
  Future<void> close() async {
    if (_closed && _subscription == null) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _bind.sessionClose(sessionId: sessionId);
    } catch (e) {
      debugPrint('failed to close the session for $peerId: $e');
    }
    _setPhase(SessionPhase.closed);
  }

  @override
  void dispose() {
    // Fire and forget: dispose cannot await, but the session must still go.
    unawaited(close());
    super.dispose();
  }
}
