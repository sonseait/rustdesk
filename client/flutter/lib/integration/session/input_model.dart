import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/session/canvas_model.dart';
import 'package:flutter_hbb/integration/session/key_maps.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

/// How key events are encoded for the peer.
///
/// These are the persisted `keyboard_mode` values and must not be renamed.
const String kKeyLegacyMode = 'legacy';
const String kKeyMapMode = 'map';
const String kKeyTranslateMode = 'translate';

/// Mouse buttons.
///
/// [mask] is Flutter's `PointerEvent.buttons` bit; [name] is what the core
/// expects on the wire. The core matches the name as a *string* and ignores
/// anything else, so sending the numeric mask silently produces no button at
/// all — the click travels but presses nothing.
enum MouseButton {
  left(1, 'left'),
  right(2, 'right'),
  wheel(4, 'wheel'),
  back(8, 'back'),
  forward(16, 'forward');

  const MouseButton(this.mask, this.name);

  final int mask;
  final String name;

  /// The button a Flutter buttons bitmask refers to, or null when it names
  /// none of them.
  static MouseButton? fromMask(int mask) {
    for (final button in values) {
      if (mask & button.mask != 0) return button;
    }
    return null;
  }
}

/// Sends keyboard and mouse input to the peer.
///
/// Ported from `InputModel` in `flutter_legacy/lib/models/input_model.dart`,
/// covering the desktop remote-control path. Relative mouse mode, edge scroll
/// and the mobile gesture translation layer arrive with later milestones.
///
/// Every send is gated on permissions and view-only state, so a session that
/// loses keyboard permission mid-stream stops sending immediately.
class InputModel {
  InputModel({
    required this.sessionId,
    required this.peerId,
    RustdeskImpl? bindOverride,
  }) : _bindOverride = bindOverride;

  final UuidValue sessionId;
  final String peerId;
  final RustdeskImpl? _bindOverride;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  /// Cached modifier state, mirrored to the peer on every event.
  bool shift = false;
  bool ctrl = false;
  bool alt = false;
  bool command = false;

  /// The peer's keyboard mode, read once the session is up.
  String keyboardMode = kKeyMapMode;

  /// Set when the session may not send input at all.
  bool viewOnly = false;

  /// Whether the peer granted keyboard control.
  bool keyboardPermission = true;

  /// The peer's platform, which changes the coordinate clamping.
  String peerPlatform = '';

  /// The buttons held on the last pointer event, for synthesizing
  /// down/up from Flutter's move events.
  int _lastButtons = 0;

  bool get canSendInput => !viewOnly && keyboardPermission;

  /// Read the keyboard mode the core negotiated for this session.
  Future<void> refreshKeyboardMode() async {
    final mode = await _bind.sessionGetKeyboardMode(sessionId: sessionId);
    if (mode != null && mode.isNotEmpty) keyboardMode = mode;
  }

  // ---------------------------------------------------------------- keyboard

  /// Handle a Flutter key event.
  ///
  /// Returns handled for every event once a session is up, so the key does not
  /// also trigger local shortcuts while the user is typing into the peer.
  KeyEventResult handleKeyEvent(KeyEvent event) {
    if (!canSendInput) return KeyEventResult.handled;

    // Meta would make the Flutter window lose focus on Windows and Linux.
    if ((isWindows || isLinux) &&
        (event.physicalKey == PhysicalKeyboardKey.metaLeft ||
            event.physicalKey == PhysicalKeyboardKey.metaRight)) {
      return KeyEventResult.handled;
    }

    _updateModifiers(event);

    if (keyboardMode == kKeyMapMode || keyboardMode == kKeyTranslateMode) {
      _sendMapMode(event);
    } else {
      _sendLegacyMode(event);
    }
    return KeyEventResult.handled;
  }

  void _updateModifiers(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (event is! KeyDownEvent && event is! KeyUpEvent) return;

    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      shift = down;
    } else if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      ctrl = down;
    } else if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      alt = down;
    } else if (key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      command = down;
    }
  }

  /// Map mode sends the raw USB HID usage, so the peer reproduces the exact
  /// physical key regardless of either side's layout.
  void _sendMapMode(KeyEvent event) {
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    _bind.sessionHandleFlutterKeyEvent(
      sessionId: sessionId,
      character: event.character ?? '',
      // The low 16 bits are the HID usage; the page is in the high bits.
      usbHid: event.physicalKey.usbHidUsage & 0xFFFF,
      lockModes: buildLockModes(),
      downOrUp: down,
    );
  }

  /// Legacy mode sends a key name the peer looks up in its own table.
  void _sendLegacyMode(KeyEvent event) {
    if (event is KeyDownEvent) {
      _sendNamedKey(event, down: true);
    } else if (event is KeyRepeatEvent) {
      _sendNamedKey(event, press: true);
    } else if (event is KeyUpEvent) {
      _sendNamedKey(event);
    }
  }

  void _sendNamedKey(KeyEvent event, {bool? down, bool? press}) {
    // Prefer the physical map, then the logical one, then the raw label —
    // the same fallback order the legacy client used for compatibility.
    final name = physicalKeyMap[event.physicalKey.usbHidUsage] ??
        logicalKeyMap[event.logicalKey.keyId] ??
        event.logicalKey.keyLabel;
    inputKey(name, down: down, press: press ?? false);
  }

  /// Send a named key stroke.
  void inputKey(String name, {bool? down, bool? press}) {
    if (!canSendInput) return;
    _bind.sessionInputKey(
      sessionId: sessionId,
      name: name,
      down: down ?? false,
      press: press ?? true,
      alt: alt,
      ctrl: ctrl,
      shift: shift,
      command: command,
    );
  }

  /// Send text directly, for paste and IME composition.
  Future<void> inputString(String value) async {
    if (!canSendInput) return;
    await _bind.sessionInputString(sessionId: sessionId, value: value);
  }

  /// Clear cached modifiers.
  ///
  /// Called when the canvas loses focus, so a modifier held at the moment of
  /// switching away does not stay stuck down on the peer.
  void resetModifiers() {
    shift = ctrl = alt = command = false;
  }

  // ------------------------------------------------------------------- mouse

  /// Apply the cached modifiers to an outgoing event map.
  Map<String, dynamic> withModifiers(Map<String, dynamic> event) {
    if (ctrl) event['ctrl'] = 'true';
    if (shift) event['shift'] = 'true';
    if (alt) event['alt'] = 'true';
    if (command) event['command'] = 'true';
    return event;
  }

  /// Send a mouse button event without a position.
  Future<void> sendMouseButton(String type, MouseButton button) async {
    if (!canSendInput) return;
    await _bind.sessionSendMouse(
      sessionId: sessionId,
      msg: json.encode(withModifiers({'type': type, 'buttons': button.name})),
    );
  }

  /// Send a down then an up: a click.
  Future<void> tap(MouseButton button) async {
    await sendMouseButton(kMouseEventTypeDown, button);
    await sendMouseButton(kMouseEventTypeUp, button);
  }

  /// Send a scroll of [y] notches (and optionally [x]).
  Future<void> scroll(int y, {int x = 0}) async {
    if (!canSendInput) return;
    final msg = <String, dynamic>{
      'id': peerId,
      'type': kMouseEventTypeWheel,
      'y': y.toString(),
    };
    if (x != 0) msg['x'] = x.toString();
    await _bind.sessionSendMouse(
      sessionId: sessionId,
      msg: json.encode(withModifiers(msg)),
    );
  }

  /// Send a positioned mouse event.
  ///
  /// [local] is the pointer position inside the canvas; it is mapped onto the
  /// remote screen and dropped when it falls outside.
  Future<void> sendPointerEvent({
    required String type,
    required Offset local,
    required CanvasCoords canvas,
    required Rect rect,
    int buttons = 0,
    String kind = kPointerEventKindMouse,
    bool onExit = false,
  }) async {
    if (!canSendInput) return;
    final remote = remotePointFromLocal(
      x: local.dx,
      y: local.dy,
      canvas: canvas,
      rect: rect,
      peerPlatform: peerPlatform,
      kind: kind,
      eventType: type,
      onExit: onExit,
      buttons: buttons == 0 ? kPrimaryMouseButton : buttons,
    );
    // Outside the remote screen: nothing to send.
    if (remote == null) return;

    final msg = <String, dynamic>{
      'type': type,
      'x': remote.dx.round().toString(),
      'y': remote.dy.round().toString(),
    };
    // A move carries no button; a press or release must name one.
    final button = MouseButton.fromMask(buttons);
    if (button != null) msg['buttons'] = button.name;

    await _bind.sessionSendMouse(
      sessionId: sessionId,
      msg: json.encode(withModifiers(msg)),
    );
  }

  /// Translate a Flutter pointer event into a type and button mask.
  ///
  /// Flutter reports a move when one button is pressed while another is
  /// already held, so a move whose button mask changed is really a press or a
  /// release. Ported from `_getMouseEvent`.
  ({String type, int buttons}) resolvePointer(
      PointerEvent event, String requestedType) {
    var type = requestedType;
    var buttons = _lastButtons;

    final staleUp =
        requestedType == kMouseEventTypeUp && event.buttons == _lastButtons;

    if (requestedType == kMouseEventTypeMove) {
      if (event.buttons != _lastButtons) {
        final delta = event.buttons - _lastButtons;
        if (delta > 0) {
          type = kMouseEventTypeDown;
          buttons = delta;
        } else {
          type = kMouseEventTypeUp;
          buttons = -delta;
        }
      }
    } else if (event.buttons != 0) {
      buttons = event.buttons;
    }

    _lastButtons = staleUp ? 0 : event.buttons;
    return (type: type, buttons: buttons);
  }

  /// Reset button tracking, e.g. when the pointer leaves the canvas.
  void resetButtons() {
    _lastButtons = 0;
  }
}

/// Build the lock-key bitmask the core expects.
///
/// Bit 1 is caps lock, bit 2 num lock, bit 3 scroll lock.
int buildLockModes({bool iosCapsLock = false}) {
  const capsLock = 1;
  const numLock = 2;
  const scrollLock = 3;
  var modes = 0;
  if (isIOS) {
    if (iosCapsLock) modes |= 1 << capsLock;
    // NumLock and ScrollLock are not meaningful on iOS.
    return modes;
  }
  final enabled = HardwareKeyboard.instance.lockModesEnabled;
  if (enabled.contains(KeyboardLockMode.capsLock)) modes |= 1 << capsLock;
  if (enabled.contains(KeyboardLockMode.numLock)) modes |= 1 << numLock;
  if (enabled.contains(KeyboardLockMode.scrollLock)) modes |= 1 << scrollLock;
  return modes;
}

/// The rect of [display] in the peer's coordinate space.
///
/// A multi-monitor peer places each display at its own origin, so input has to
/// be offset by it rather than assuming (0,0).
Rect displayRect(PeerInfo peerInfo, {int? display}) {
  final target = peerInfo.tryGetDisplay(display: display);
  if (target == null) return Rect.zero;
  if (peerInfo.currentDisplay == kAllDisplayValue) {
    // The combined view spans every display, so use the union.
    var union = Rect.fromLTWH(
      peerInfo.displays.first.x,
      peerInfo.displays.first.y,
      peerInfo.displays.first.width.toDouble(),
      peerInfo.displays.first.height.toDouble(),
    );
    for (final d in peerInfo.displays.skip(1)) {
      union = union.expandToInclude(Rect.fromLTWH(
          d.x, d.y, d.width.toDouble(), d.height.toDouble()));
    }
    return union;
  }
  return Rect.fromLTWH(
      target.x, target.y, target.width.toDouble(), target.height.toDouble());
}
