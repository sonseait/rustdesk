import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// A window's last size, position and maximised/fullscreen state.
///
/// Ported from `LastWindowPosition` in `flutter_legacy/lib/common.dart`. The
/// JSON keys are what the core already has on disk, so a rename loses every
/// saved window position.
@immutable
class WindowFrame {
  const WindowFrame({
    this.width,
    this.height,
    this.offsetWidth,
    this.offsetHeight,
    this.isMaximized,
    this.isFullscreen,
  });

  final double? width;
  final double? height;
  final double? offsetWidth;
  final double? offsetHeight;
  final bool? isMaximized;
  final bool? isFullscreen;

  /// Parse a stored frame. Returns null for empty or malformed content rather
  /// than a frame of nulls, so a caller can tell "nothing saved" from "saved
  /// with no size".
  static WindowFrame? parse(String content) {
    if (content.isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      return WindowFrame(
        width: _toDouble(decoded['width']),
        height: _toDouble(decoded['height']),
        offsetWidth: _toDouble(decoded['offsetWidth']),
        offsetHeight: _toDouble(decoded['offsetHeight']),
        isMaximized: decoded['isMaximized'] as bool?,
        isFullscreen: decoded['isFullscreen'] as bool?,
      );
    } catch (e) {
      debugPrint('failed to parse a saved window frame "$content": $e');
      return null;
    }
  }

  static double? _toDouble(dynamic raw) {
    if (raw is num) return raw.toDouble();
    return null;
  }

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'offsetWidth': offsetWidth,
        'offsetHeight': offsetHeight,
        'isMaximized': isMaximized,
        'isFullscreen': isFullscreen,
      };

  @override
  String toString() => jsonEncode(toJson());

  WindowFrame copyWith({
    double? width,
    double? height,
    double? offsetWidth,
    double? offsetHeight,
    bool? isMaximized,
    bool? isFullscreen,
  }) =>
      WindowFrame(
        width: width ?? this.width,
        height: height ?? this.height,
        offsetWidth: offsetWidth ?? this.offsetWidth,
        offsetHeight: offsetHeight ?? this.offsetHeight,
        isMaximized: isMaximized ?? this.isMaximized,
        isFullscreen: isFullscreen ?? this.isFullscreen,
      );

  /// This frame shifted by [offset], used to stagger a second window of the
  /// same type rather than stacking it exactly on the first.
  WindowFrame shifted(double offset) => copyWith(
        offsetWidth: offsetWidth == null ? null : offsetWidth! + offset,
        offsetHeight: offsetHeight == null ? null : offsetHeight! + offset,
      );

  Size? get size =>
      width == null || height == null ? null : Size(width!, height!);

  Offset? get offset => offsetWidth == null || offsetHeight == null
      ? null
      : Offset(offsetWidth!, offsetHeight!);

  @override
  bool operator ==(Object other) =>
      other is WindowFrame &&
      other.width == width &&
      other.height == height &&
      other.offsetWidth == offsetWidth &&
      other.offsetHeight == offsetHeight &&
      other.isMaximized == isMaximized &&
      other.isFullscreen == isFullscreen;

  @override
  int get hashCode => Object.hash(
      width, height, offsetWidth, offsetHeight, isMaximized, isFullscreen);
}

/// How far each additional window of the same type is offset, so two windows
/// do not land exactly on top of each other. Matches `kNewWindowOffset`.
double get kNewWindowOffset {
  if (isWindows) return 56;
  if (isLinux) return 50;
  if (isMacOS) return 30;
  return 50;
}

/// Reads and writes the saved window frames.
///
/// Frames live in the core's local flutter options under the `wm_` prefix,
/// with a separate namespace for incoming-only and outgoing-only builds: those
/// have different window layouts, so sharing one saved frame would restore a
/// window sized for the wrong UI.
class WindowFrameStore {
  WindowFrameStore();

  static final WindowFrameStore instance = WindowFrameStore();

  /// A build's frame namespace, e.g. `wm_incoming_`.
  String get keyPrefix {
    try {
      if (bind.isIncomingOnly()) return '${kWindowPrefix}incoming_';
      if (bind.isOutgoingOnly()) return '${kWindowPrefix}outgoing_';
    } catch (e) {
      debugPrint('failed to read the build flavour: $e');
    }
    return kWindowPrefix;
  }

  String keyFor(WindowType type) => '$keyPrefix${type.name}';

  /// Whether the deployment turned position restore off.
  ///
  /// The legacy code honours this environment variable, which exists for
  /// window managers that place windows themselves.
  bool get isRestoreDisabled {
    try {
      return bind
          .mainGetEnv(key: 'DISABLE_RUSTDESK_RESTORE_WINDOW_POSITION')
          .isNotEmpty;
    } catch (e) {
      debugPrint('failed to read the restore-position environment: $e');
      return false;
    }
  }

  // ------------------------------------------------------------- per type

  /// The frame saved for [type], or null when none is.
  WindowFrame? frameOf(WindowType type) {
    try {
      return WindowFrame.parse(bind.getLocalFlutterOption(k: keyFor(type)));
    } catch (e) {
      debugPrint('failed to read the frame for ${type.name}: $e');
      return null;
    }
  }

  Future<void> saveFrame(WindowType type, WindowFrame frame) async {
    try {
      await bind.setLocalFlutterOption(k: keyFor(type), v: frame.toString());
    } catch (e) {
      debugPrint('failed to save the frame for ${type.name}: $e');
    }
  }

  // ------------------------------------------------------------- per peer

  /// The frame saved for [peerId] on a session window type.
  ///
  /// Only remote desktop and camera windows keep a per-peer frame; the legacy
  /// code stores one because those windows are sized to a specific display.
  WindowFrame? peerFrameOf(WindowType type, String peerId) {
    if (!_keepsPeerFrame(type) || peerId.isEmpty) return null;
    try {
      return WindowFrame.parse(
          bind.mainGetPeerFlutterOptionSync(id: peerId, k: keyFor(type)));
    } catch (e) {
      debugPrint('failed to read the frame for peer $peerId: $e');
      return null;
    }
  }

  void savePeerFrame(WindowType type, String peerId, WindowFrame frame) {
    if (!_keepsPeerFrame(type) || peerId.isEmpty) return;
    try {
      bind.mainSetPeerFlutterOptionSync(
          id: peerId, k: keyFor(type), v: frame.toString());
    } catch (e) {
      debugPrint('failed to save the frame for peer $peerId: $e');
    }
  }

  static bool _keepsPeerFrame(WindowType type) =>
      type == WindowType.RemoteDesktop || type == WindowType.ViewCamera;

  /// What to store for [peerId] when a window closes.
  ///
  /// A maximised or fullscreen window has no useful size of its own, so the
  /// peer keeps its previous size and only the maximised/fullscreen flags are
  /// updated. Restoring it later then un-maximises to a sensible size instead
  /// of to whatever the screen happened to be.
  WindowFrame peerFrameToSave(
    WindowType type,
    String peerId,
    WindowFrame frame,
  ) {
    final isSpecial =
        (frame.isMaximized ?? false) || (frame.isFullscreen ?? false);
    if (!isSpecial) return frame;
    final previous = peerFrameOf(type, peerId);
    return WindowFrame(
      width: previous?.width ?? frame.width,
      height: previous?.height ?? frame.height,
      offsetWidth: previous?.offsetWidth ?? frame.offsetWidth,
      offsetHeight: previous?.offsetHeight ?? frame.offsetHeight,
      isMaximized: frame.isMaximized,
      isFullscreen: frame.isFullscreen,
    );
  }

  // ------------------------------------------------------------- restoring

  /// The frame to open a window of [type] with, or null to let the platform
  /// place it.
  ///
  /// A peer's own frame wins when there is one, and is used as-is: it already
  /// describes where that session belongs. A shared frame is staggered by
  /// [windowId] and [display] so a second window does not cover the first.
  WindowFrame? restoreFrame(
    WindowType type, {
    int? windowId,
    String? peerId,
    int? display,
  }) {
    if (isRestoreDisabled) return null;

    final peerFrame =
        peerId == null ? null : peerFrameOf(type, peerId);
    if (peerFrame != null) return _clamp(peerFrame);

    final frame = frameOf(type);
    if (frame == null) return null;

    var shifted = frame;
    if (_keepsPeerFrame(type)) {
      if (windowId != null) shifted = shifted.shifted(windowId * kNewWindowOffset);
      if (display != null) shifted = shifted.shifted(display * kNewWindowOffset);
    }
    return _clamp(shifted);
  }

  /// Sizes below or above what a real window can be come back as the default.
  ///
  /// A saved frame can be nonsense after a display change; restoring it
  /// literally would open a window that is invisible or larger than every
  /// screen.
  static const double _minSide = 1;
  static const double _maxSide = 6480;
  static const double _defaultWidth = 1280;
  static const double _defaultHeight = 720;

  /// The furthest a window may be placed before the position is dropped and
  /// the platform centres it instead.
  static const double _maxOffset = 3840;

  WindowFrame _clamp(WindowFrame frame) {
    final width = _clampSide(frame.width, _defaultWidth);
    final height = _clampSide(frame.height, _defaultHeight);
    final offset = _clampOffset(frame, width, height);
    return frame.copyWith(width: width, height: height).withOffset(offset);
  }

  static double _clampSide(double? side, double fallback) {
    if (side == null || side < _minSide || side > _maxSide) return fallback;
    return side;
  }

  /// The offset to use, or null when the window would land off every screen.
  static Offset? _clampOffset(WindowFrame frame, double width, double height) {
    final left = frame.offsetWidth;
    final top = frame.offsetHeight;
    if (left == null || top == null) return null;
    // A window whose right edge is left of the desktop, or whose left edge is
    // past its right edge, is unreachable; centring beats hiding it.
    const minVisible = 10.0;
    if (left + minVisible > _maxOffset ||
        top + minVisible > _maxOffset ||
        left + width - minVisible < 0 ||
        top < 0) {
      return null;
    }
    return Offset(left, top);
  }
}

extension on WindowFrame {
  /// This frame with an explicit offset, where null means "let the platform
  /// place it" rather than "keep the old offset" — which is why copyWith
  /// cannot express it.
  WindowFrame withOffset(Offset? offset) => WindowFrame(
        width: width,
        height: height,
        offsetWidth: offset?.dx,
        offsetHeight: offset?.dy,
        isMaximized: isMaximized,
        isFullscreen: isFullscreen,
      );
}

/// The process-wide window frame store.
WindowFrameStore get windowFrames => WindowFrameStore.instance;
