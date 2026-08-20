import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

/// How the remote image is scrolled when it is larger than the viewport.
enum ScrollStyle { scrollauto, scrollbar }

/// Scale of the remote image for a given view style and viewport.
///
/// Ported from `ViewStyle` in `flutter_legacy/lib/models/model.dart`.
@immutable
class ViewStyle {
  const ViewStyle({
    required this.style,
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
  });

  /// Viewport size.
  final String style;
  final double width;
  final double height;

  /// Remote display size.
  final int displayWidth;
  final int displayHeight;

  /// Compared at 1/100 precision, matching the legacy equality: sub-pixel
  /// viewport jitter must not cause a re-layout.
  static int _quantize(double v) => (v * 100).round();

  @override
  bool operator ==(Object other) =>
      other is ViewStyle &&
      other.style == style &&
      _quantize(other.width) == _quantize(width) &&
      _quantize(other.height) == _quantize(height) &&
      other.displayWidth == displayWidth &&
      other.displayHeight == displayHeight;

  @override
  int get hashCode => Object.hash(style, _quantize(width), _quantize(height),
      displayWidth, displayHeight);

  /// The scale factor this style implies.
  ///
  /// Adaptive fits the image inside the viewport, preserving aspect ratio.
  /// Original and custom are 1.0 here; custom is applied by the caller from
  /// the session's stored percent.
  double get scale {
    if (style != kRemoteViewStyleAdaptive) return 1.0;
    if (width == 0 || height == 0 || displayWidth == 0 || displayHeight == 0) {
      return 1.0;
    }
    return min(width / displayWidth, height / displayHeight);
  }
}

/// The canvas geometry input needs to map a local point onto the remote
/// screen. Passed by value so the transform stays a pure function.
@immutable
class CanvasCoords {
  const CanvasCoords({
    required this.size,
    required this.x,
    required this.y,
    required this.scale,
    required this.scrollX,
    required this.scrollY,
    required this.scrollStyle,
  });

  final Size size;
  final double x;
  final double y;
  final double scale;
  final double scrollX;
  final double scrollY;
  final ScrollStyle scrollStyle;
}

/// Geometry of the remote image inside the local viewport.
///
/// Ported from `CanvasModel` in `flutter_legacy/lib/models/model.dart`, minus
/// the pieces that belong to later milestones (edge scroll, mobile soft
/// keyboard offsets).
class CanvasModel extends ChangeNotifier {
  CanvasModel();

  double _x = 0;
  double _y = 0;
  double _scale = 1.0;
  double _devicePixelRatio = 1.0;
  double _scrollX = 0;
  double _scrollY = 0;
  ScrollStyle _scrollStyle = ScrollStyle.scrollauto;
  Size _size = Size.zero;
  String _viewStyle = kRemoteViewStyleOriginal;
  ViewStyle? _lastViewStyle;

  double get x => _x;
  double get y => _y;
  double get scale => _scale;
  double get scrollX => _scrollX;
  double get scrollY => _scrollY;
  ScrollStyle get scrollStyle => _scrollStyle;
  Size get size => _size;
  String get viewStyle => _viewStyle;
  double get devicePixelRatio => _devicePixelRatio;

  /// True when the scaled image is larger than the viewport.
  bool get isImageOverflow => _x < 0 || _y < 0;

  CanvasCoords get coords => CanvasCoords(
        size: _size,
        x: _x,
        y: _y,
        scale: _scale,
        scrollX: _scrollX,
        scrollY: _scrollY,
        scrollStyle: _scrollStyle,
      );

  /// Recompute geometry for a viewport and remote display.
  ///
  /// [customScale] is the session's stored percent, used only in custom mode.
  /// [devicePixelRatio] divides the scale for original and custom styles,
  /// matching the legacy `kIgnoreDpi` behavior — without it the image renders
  /// at double size on a retina display.
  void update({
    required Size viewport,
    required RemoteDisplay display,
    required String style,
    double customScale = 1.0,
    double devicePixelRatio = 1.0,
  }) {
    _size = viewport;
    _viewStyle = style;
    _devicePixelRatio = devicePixelRatio;

    final viewStyle = ViewStyle(
      style: style,
      width: viewport.width,
      height: viewport.height,
      displayWidth: display.width,
      displayHeight: display.height,
    );

    // A style change resets scroll; a pure size change does not.
    if (_lastViewStyle != null && _lastViewStyle!.style != viewStyle.style) {
      _scrollX = 0;
      _scrollY = 0;
    }
    _lastViewStyle = viewStyle;

    var scale = viewStyle.scale;
    if (style == kRemoteViewStyleCustom) scale = customScale;
    if (style == kRemoteViewStyleOriginal) {
      scale = 1.0 / devicePixelRatio;
    } else if (style == kRemoteViewStyleCustom && scale != 0) {
      scale /= devicePixelRatio;
    }
    _scale = scale;

    _resetOffset(display);
    notifyListeners();
  }

  /// Geometry for an image the widget has already fitted and centred.
  ///
  /// [viewport] is the laid-out image box, so the scale is simply its size
  /// over the remote size and there is no centring offset. The general
  /// [update] path is for surfaces that place the image themselves.
  void updateFitted({required Size viewport, required Size remote}) {
    if (remote.width <= 0 || remote.height <= 0) return;
    _size = viewport;
    _scale = viewport.width / remote.width;
    // The box is the image, so its origin is the image's origin.
    _x = 0;
    _y = 0;
    notifyListeners();
  }

  /// Center the image, or pin it to the origin when it overflows.
  void _resetOffset(RemoteDisplay display) {
    final imageWidth = display.width * _scale;
    final imageHeight = display.height * _scale;
    _x = (_size.width - imageWidth) / 2;
    _y = (_size.height - imageHeight) / 2;
  }

  void setScrollStyle(ScrollStyle style) {
    if (_scrollStyle == style) return;
    _scrollStyle = style;
    _scrollX = 0;
    _scrollY = 0;
    notifyListeners();
  }

  /// Scroll offsets are normalized 0..1 fractions of the image.
  void setScroll(double x, double y) {
    final nextX = x.clamp(0.0, 1.0);
    final nextY = y.clamp(0.0, 1.0);
    if (_scrollX == nextX && _scrollY == nextY) return;
    _scrollX = nextX;
    _scrollY = nextY;
    notifyListeners();
  }

  void clear() {
    _x = 0;
    _y = 0;
    _scale = 1.0;
    _scrollX = 0;
    _scrollY = 0;
    _lastViewStyle = null;
    notifyListeners();
  }
}

/// Map a local point onto the remote screen.
///
/// Ported from `_handlePointerDevicePos` in
/// `flutter_legacy/lib/models/input_model.dart`. Returns null when the point
/// falls outside the remote rect and must not be sent.
///
/// [rect] is the remote display's rect in remote coordinates, so a multi-
/// monitor peer maps into the right screen.
Offset? remotePointFromLocal({
  required double x,
  required double y,
  required CanvasCoords canvas,
  required Rect rect,
  required String peerPlatform,
  required String kind,
  required String eventType,
  bool onExit = false,
  int buttons = kPrimaryMouseButton,
}) {
  const nearThreshold = 3;
  final nearRight = (canvas.size.width - x) < nearThreshold;
  final nearBottom = (canvas.size.height - y) < nearThreshold;
  final imageWidth = rect.width * canvas.scale;
  final imageHeight = rect.height * canvas.scale;

  var localX = x;
  var localY = y;

  if (canvas.scrollStyle != ScrollStyle.scrollauto) {
    localX += imageWidth * canvas.scrollX;
    localY += imageHeight * canvas.scrollY;
    // The image is centered when it is smaller than the viewport.
    if (canvas.size.width > imageWidth) {
      localX -= (canvas.size.width - imageWidth) / 2;
    }
    if (canvas.size.height > imageHeight) {
      localY -= (canvas.size.height - imageHeight) / 2;
    }
  } else {
    localX -= canvas.x;
    localY -= canvas.y;
  }

  localX /= canvas.scale;
  localY /= canvas.scale;

  // When zoomed out, the last local pixel covers more than one remote pixel;
  // nudge to the far edge so the remote edge stays reachable.
  if (canvas.scale > 0 && canvas.scale < 1) {
    final step = 1.0 / canvas.scale - 1;
    if (nearRight) localX += step;
    if (nearBottom) localY += step;
  }

  localX += rect.left;
  localY += rect.top;

  if (onExit) {
    final edge = nearestEdge(localX, localY, rect);
    localX = edge.dx;
    localY = edge.dy;
  }

  return pointInRemoteRect(
    peerPlatform: peerPlatform,
    kind: kind,
    eventType: eventType,
    x: localX,
    y: localY,
    rect: rect,
    buttons: buttons,
  );
}

/// Clamp a remote point into [rect], or reject it.
///
/// Ported from `getPointInRemoteRect`. Windows needs the inclusive maximum so
/// window snapping works: https://github.com/rustdesk/rustdesk/issues/6678
Offset? pointInRemoteRect({
  required String peerPlatform,
  required String kind,
  required String eventType,
  required double x,
  required double y,
  required Rect rect,
  int buttons = kPrimaryMouseButton,
}) {
  final inset = peerPlatform == 'Windows' ? 0 : 1;
  final minX = rect.left;
  final maxX = rect.left + rect.width - inset;
  final minY = rect.top;
  final maxY = rect.top + rect.height - inset;

  var evtX = _snapToRange(x, minX, maxX, 5);
  var evtY = _snapToRange(y, minY, maxY, 5);

  if (evtX < minX || evtY < minY || evtX > maxX || evtY > maxY) {
    // A left-button release outside the rect still has to be delivered, or
    // the remote side is left with a stuck button.
    final isReleasingPrimary =
        buttons == kPrimaryMouseButton && eventType == kMouseEventTypeUp;
    if (!isReleasingPrimary) return null;
    evtX = evtX.clamp(minX, maxX);
    evtY = evtY.clamp(minY, maxY);
  }
  return Offset(evtX, evtY);
}

/// Snap a value that is just outside a range back into it.
double _snapToRange(double value, double min, double max, double threshold) {
  if (value < min && min - value <= threshold) return min;
  if (value > max && value - max <= threshold) return max;
  return value;
}

/// The point on [rect]'s border nearest to (x, y), used when the pointer
/// leaves the canvas so the remote cursor stops at the edge.
Offset nearestEdge(double x, double y, Rect rect) {
  final left = (x - rect.left).abs();
  final right = (rect.right - x).abs();
  final top = (y - rect.top).abs();
  final bottom = (rect.bottom - y).abs();
  final nearest = [left, right, top, bottom].reduce(min);
  if (nearest == left) return Offset(rect.left, y);
  if (nearest == right) return Offset(rect.right - 1, y);
  if (nearest == top) return Offset(x, rect.top);
  return Offset(x, rect.bottom - 1);
}

/// Mouse event type strings shared with the Rust core.
const String kMouseEventTypeDown = 'down';
const String kMouseEventTypeUp = 'up';
const String kMouseEventTypeWheel = 'wheel';

/// A plain move carries an *empty* type.
///
/// The core matches `down`, `up`, `wheel`, `trackpad` and `move_relative` and
/// treats anything else as no action. A move is expressed by sending only the
/// position, so naming it 'move' makes the core discard the event.
const String kMouseEventTypeMove = '';

/// Pointer device kinds the core distinguishes.
const String kPointerEventKindMouse = 'mouse';
const String kPointerEventKindTouch = 'touch';
