import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/session/canvas_model.dart';
import 'package:flutter_hbb/integration/session/chat_model.dart';
import 'package:flutter_hbb/integration/session/file_transfer_adapter.dart';
import 'package:flutter_hbb/integration/session/image_model.dart';
import 'package:flutter_hbb/integration/session/input_model.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';
import 'package:flutter_hbb/integration/session/port_forward_model.dart';
import 'package:flutter_hbb/integration/session/session_adapter.dart';
import 'package:flutter_hbb/integration/session/session_options.dart';
import 'package:flutter_hbb/integration/session/terminal_model.dart';
import 'package:flutter_hbb/integration/session/texture_model.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// What the session surface should be showing right now.
enum SessionStage {
  /// Establishing the connection, or waiting for the first frame.
  connecting,

  /// Frames are flowing.
  live,

  /// The core needs credentials or a confirmation.
  prompt,

  /// The session ended.
  closed,

  /// The session could not be established.
  failed,
}

/// Backs the session surface with one live session.
///
/// Owns the [SessionAdapter], [TextureModel], [CanvasModel] and [InputModel]
/// for a single peer, and exposes the state the UI renders. Widgets never talk
/// to the adapters directly, so the same surface can be driven by a fake in
/// tests.
class SessionViewModel extends ChangeNotifier {
  SessionViewModel({
    required this.peerId,
    this.kind = ConnectionKind.remoteDesktop,
    SessionAdapter? session,
    TextureModel? textures,
    CanvasModel? canvas,
    InputModel? input,
    ImageModel? images,
  }) : _session = session ?? SessionAdapter(peerId: peerId, kind: kind) {
    _textures = textures ?? TextureModel(sessionId: _session.sessionId);
    _images = images ?? ImageModel(sessionId: _session.sessionId);
    _canvas = canvas ?? CanvasModel();
    _input = input ?? InputModel(sessionId: _session.sessionId, peerId: peerId);
  }

  final String peerId;
  final ConnectionKind kind;

  final SessionAdapter _session;
  late final TextureModel _textures;
  late final ImageModel _images;
  FileTransferAdapter? _files;
  TerminalRegistry? _terminals;
  ChatModel? _chat;
  SessionOptions? _options;
  PortForwardModel? _portForwards;
  late final CanvasModel _canvas;
  late final InputModel _input;

  bool _started = false;
  bool _disposed = false;
  bool _waylandModeNormalized = false;
  bool _optionsPrimed = false;
  bool _usesTexture = false;
  String _viewStyle = kRemoteViewStyleAdaptive;

  SessionAdapter get session => _session;
  TextureModel get textures => _textures;
  ImageModel get images => _images;

  /// The file transfer surface, created on first use so a plain desktop
  /// session does not pay for it.
  FileTransferAdapter get files =>
      _files ??= FileTransferAdapter(sessionId: _session.sessionId)
        ..start(isPeerWindows: peerInfo.isPeerWindows);

  /// The terminal surface, likewise created on first use.
  TerminalRegistry get terminals =>
      _terminals ??= TerminalRegistry(sessionId: _session.sessionId);

  ChatModel get chat =>
      _chat ??= ChatModel(sessionId: _session.sessionId)..addListener(_notify);

  /// Clipboard, audio, recording and the other per-session switches.
  SessionOptions get options => _options ??=
      SessionOptions(sessionId: _session.sessionId)..addListener(_notify);

  PortForwardModel get portForwards => _portForwards ??= PortForwardModel(
        sessionId: _session.sessionId,
        peerId: peerId,
      )..refresh();

  /// Messages received while the chat panel was closed.
  int get unreadChatCount => _chat?.unreadCount ?? 0;
  CanvasModel get canvas => _canvas;
  InputModel get input => _input;

  PeerInfo get peerInfo => _session.peerInfo;

  SessionPrompt? get prompt => _session.prompt;

  Object? get error => _session.error;

  String get viewStyle => _viewStyle;

  /// The display currently shown, or [kAllDisplayValue].
  int get currentDisplay => _session.currentDisplay;

  List<RemoteDisplay> get displays => peerInfo.displays;

  bool get isMultiDisplay => displays.length > 1;

  /// True when the peer granted keyboard control and the user has not
  /// switched to view-only.
  bool get canSendInput => _input.canSendInput;

  bool get isViewOnly => _input.viewOnly;

  bool get isSecure => _session.isSecure;

  bool get isDirect => _session.isDirect;

  /// True when the core renders through a native texture rather than handing
  /// Flutter raw frames.
  bool get usesTextureRender => _usesTexture;

  /// The remote rect for the current display, used to map input.
  ///
  /// Once a frame has been decoded its geometry wins: a scaled peer captures
  /// at a size that need not match either reported dimension, and input has to
  /// map onto the pixels actually being shown.
  Rect get remoteRect {
    final frame = _images.frameSize;
    if (frame != null && !usesTextureRender) {
      final rect = displayRect(peerInfo);
      return Rect.fromLTWH(
          rect.left, rect.top, frame.$1.toDouble(), frame.$2.toDouble());
    }
    return displayRect(peerInfo);
  }

  SessionStage get stage {
    if (_session.prompt?.needsCredentials == true) return SessionStage.prompt;
    switch (_session.phase) {
      case SessionPhase.failed:
        return SessionStage.failed;
      case SessionPhase.closed:
        return SessionStage.closed;
      case SessionPhase.idle:
      case SessionPhase.connecting:
        return SessionStage.connecting;
      case SessionPhase.connected:
        return _session.isWaitingForFirstFrame
            ? SessionStage.connecting
            : SessionStage.live;
    }
  }

  /// A human-readable line describing what the session is doing.
  String get statusLine {
    switch (stage) {
      case SessionStage.connecting:
        return _session.phase == SessionPhase.connected
            ? 'Waiting for the first frame…'
            : 'Connecting to $peerId…';
      case SessionStage.live:
        final parts = <String>[
          if (isSecure) 'Encrypted' else 'Not encrypted',
          if (isDirect) 'Direct' else 'Relayed',
        ];
        return parts.join(' · ');
      case SessionStage.prompt:
        return _session.prompt?.title ?? 'Waiting for credentials';
      case SessionStage.closed:
        return 'Session closed';
      case SessionStage.failed:
        return '${_session.error ?? 'Connection failed'}';
    }
  }

  /// Start the session. Safe to call once.
  Future<void> start({
    String? password,
    bool forceRelay = false,
    bool isSharedPassword = false,
    String? connToken,
    String switchUuid = '',
  }) async {
    if (_started) return;
    _started = true;

    _session.addListener(_onSessionChanged);
    _canvas.addListener(_notify);

    _session.onTextureFrame = (display, gpuTexture) {
      _usesTexture = true;
      _textures.setTextureType(display: display, gpuTexture: gpuTexture);
      _notify();
    };
    // The core decides per session whether it delivers textures or raw pixels;
    // on a default macOS build it is pixels, so this path must work too.
    _session.onRgbaFrame = (display, rgba) {
      unawaited(_images.onRgba(display, rgba, peerInfo));
    };
    // File transfer events arrive on the same session stream.
    _session.onEvent = (event) {
      _files?.handleEvent(event);
      _terminals?.handleEvent(event);
      _chat?.handleEvent(event);
    };
    _images.addListener(_notify);

    final ok = await _session.start(
      password: password,
      forceRelay: forceRelay,
      isSharedPassword: isSharedPassword,
      connToken: connToken,
      switchUuid: switchUuid,
    );
    if (!ok) return;

    await _input.refreshKeyboardMode();
    _viewStyle = await _readViewStyle();
  }

  /// Force map mode when controlling a Wayland peer.
  ///
  /// Ported from `_normalizeWaylandKeyboardModeIfNeeded` in
  /// `flutter_legacy/lib/desktop/pages/remote_page.dart`. Legacy mode sends
  /// key *names*, which Wayland cannot inject reliably; map mode sends the
  /// physical scancode and works. Runs once per session, after peer info
  /// identifies the platform.
  Future<void> _normalizeWaylandKeyboardMode() async {
    if (_waylandModeNormalized) return;
    final pi = peerInfo;
    if (!pi.isPeerLinux || !pi.isWayland) return;
    _waylandModeNormalized = true;
    try {
      final supported = bind.sessionIsKeyboardModeSupported(
          sessionId: _session.sessionId, mode: kKeyMapMode);
      if (!supported) return;
      final current =
          await bind.sessionGetKeyboardMode(sessionId: _session.sessionId);
      if (current == kKeyMapMode) return;
      await bind.sessionSetKeyboardMode(
          sessionId: _session.sessionId, value: kKeyMapMode);
      await _input.refreshKeyboardMode();
    } catch (e) {
      debugPrint('failed to normalize the Wayland keyboard mode: $e');
    }
  }

  Future<String> _readViewStyle() async {
    try {
      final style =
          await bind.sessionGetViewStyle(sessionId: _session.sessionId);
      if (style != null && style.isNotEmpty) return style;
    } catch (e) {
      debugPrint('failed to read the view style: $e');
    }
    return kRemoteViewStyleAdaptive;
  }

  void _onSessionChanged() {
    // Peer info decides how many textures are needed and how input maps.
    _input.peerPlatform = peerInfo.platform;
    _input.keyboardPermission = _session.permissions.keyboard;
    if (peerInfo.isSet) {
      unawaited(_textures.updateCurrentDisplay(currentDisplay, peerInfo));
      unawaited(_normalizeWaylandKeyboardMode());
      // The core owns these values; read them once the session is up.
      if (!_optionsPrimed) {
        _optionsPrimed = true;
        options.refresh();
      }
    }
    _notify();
  }

  /// Recompute canvas geometry for a new viewport.
  /// Recompute canvas geometry.
  ///
  /// [viewport] is the size of the *image* as laid out, not the surrounding
  /// area: the widget already fits the frame and centres it. So the canvas
  /// must not scale or centre again — it maps a point in that box straight
  /// onto the remote screen. Passing the view style here would apply the
  /// device pixel ratio a second time and double every coordinate.
  void updateViewport(Size viewport, {double devicePixelRatio = 1.0}) {
    final rect = remoteRect;
    if (rect.isEmpty) return;
    _canvas.updateFitted(viewport: viewport, remote: rect.size);
  }

  /// Change how the remote image is fitted.
  Future<void> setViewStyle(String style) async {
    if (_viewStyle == style) return;
    _viewStyle = style;
    await bind.sessionSetViewStyle(sessionId: _session.sessionId, value: style);
    _notify();
  }

  /// Show a different display, or [kAllDisplayValue] for all of them.
  Future<void> switchDisplay(int display) async {
    await _session.switchDisplay(display);
    await _textures.updateCurrentDisplay(display, peerInfo);
    _notify();
  }

  /// Toggle view-only, which stops all outgoing input.
  void setViewOnly(bool value) {
    if (_input.viewOnly == value) return;
    _input.viewOnly = value;
    // A modifier held when input stops would stay stuck on the peer.
    if (value) _input.resetModifiers();
    _notify();
  }

  Future<void> reconnect({bool forceRelay = false}) =>
      _session.reconnect(forceRelay: forceRelay);

  Future<void> submitPassword(String password, {bool remember = false}) =>
      _session.submitPassword(password, remember: remember);

  Future<void> submitTwoFactor(String code, {bool trustThisDevice = false}) =>
      _session.submitTwoFactor(code, trustThisDevice: trustThisDevice);

  void dismissPrompt() => _session.dismissPrompt();

  /// Send a key event from the canvas.
  KeyEventResult handleKeyEvent(KeyEvent event) => _input.handleKeyEvent(event);

  /// Send a positioned pointer event from the canvas.
  Future<void> sendPointer({
    required String type,
    required Offset local,
    int buttons = 0,
    bool onExit = false,
  }) =>
      _input.sendPointerEvent(
        type: type,
        local: local,
        canvas: _canvas.coords,
        rect: remoteRect,
        buttons: buttons,
        onExit: onExit,
      );

  Future<void> scroll(int y, {int x = 0}) => _input.scroll(y, x: x);

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Close the session and free its textures.
  ///
  /// Textures must be torn down before the session goes away: the core writes
  /// into them, so the order here is load-bearing.
  Future<void> close() async {
    await _textures.dispose(unregister: true);
    await _session.close();
  }

  @override
  void dispose() {
    _disposed = true;
    // Nothing was wired up if start() never ran, and there is no core session
    // to close in that case.
    if (_started) {
      _session.removeListener(_onSessionChanged);
      _canvas.removeListener(_notify);
      _images.removeListener(_notify);
      _images.dispose();
      _files?.dispose();
      _terminals?.dispose();
      _chat?.removeListener(_notify);
      _chat?.dispose();
      _options?.removeListener(_notify);
      _options?.dispose();
      _portForwards?.dispose();
      unawaited(close());
      _session.dispose();
    }
    _canvas.dispose();
    super.dispose();
  }
}
