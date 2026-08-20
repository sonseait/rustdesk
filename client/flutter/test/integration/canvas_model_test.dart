import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/session/canvas_model.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

CanvasCoords coords({
  Size size = const Size(1000, 800),
  double x = 0,
  double y = 0,
  double scale = 1.0,
  double scrollX = 0,
  double scrollY = 0,
  ScrollStyle scrollStyle = ScrollStyle.scrollauto,
}) =>
    CanvasCoords(
      size: size,
      x: x,
      y: y,
      scale: scale,
      scrollX: scrollX,
      scrollY: scrollY,
      scrollStyle: scrollStyle,
    );

void main() {
  group('ViewStyle.scale', () {
    test('adaptive fits the image inside the viewport', () {
      // A 1920x1080 display in a 960x800 viewport fits by width.
      const style = ViewStyle(
        style: kRemoteViewStyleAdaptive,
        width: 960,
        height: 800,
        displayWidth: 1920,
        displayHeight: 1080,
      );

      expect(style.scale, closeTo(0.5, 0.0001));
    });

    test('adaptive picks the smaller ratio so nothing is cropped', () {
      const style = ViewStyle(
        style: kRemoteViewStyleAdaptive,
        width: 1920,
        height: 540,
        displayWidth: 1920,
        displayHeight: 1080,
      );

      expect(style.scale, closeTo(0.5, 0.0001));
    });

    test('original is unscaled', () {
      const style = ViewStyle(
        style: kRemoteViewStyleOriginal,
        width: 500,
        height: 500,
        displayWidth: 1920,
        displayHeight: 1080,
      );

      expect(style.scale, 1.0);
    });

    test('a zero dimension does not divide by zero', () {
      const style = ViewStyle(
        style: kRemoteViewStyleAdaptive,
        width: 0,
        height: 0,
        displayWidth: 1920,
        displayHeight: 1080,
      );

      expect(style.scale, 1.0);
    });

    test('equality quantizes at 1/100 so sub-pixel jitter is ignored', () {
      const a = ViewStyle(
        style: kRemoteViewStyleAdaptive,
        width: 960.0001,
        height: 800,
        displayWidth: 1920,
        displayHeight: 1080,
      );
      const b = ViewStyle(
        style: kRemoteViewStyleAdaptive,
        width: 960.0002,
        height: 800,
        displayWidth: 1920,
        displayHeight: 1080,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('CanvasModel.update', () {
    const display = RemoteDisplay(width: 1920, height: 1080);

    test('adaptive centers the scaled image', () {
      final canvas = CanvasModel();
      canvas.update(
        viewport: const Size(1920, 1080),
        display: display,
        style: kRemoteViewStyleAdaptive,
      );

      expect(canvas.scale, 1.0);
      expect(canvas.x, 0);
      expect(canvas.y, 0);
      expect(canvas.isImageOverflow, isFalse);
    });

    test('a smaller viewport scales down and stays centered', () {
      final canvas = CanvasModel();
      canvas.update(
        viewport: const Size(960, 800),
        display: display,
        style: kRemoteViewStyleAdaptive,
      );

      expect(canvas.scale, closeTo(0.5, 0.0001));
      // 1920*0.5 = 960 fills the width; 1080*0.5 = 540 leaves 130 above.
      expect(canvas.x, closeTo(0, 0.01));
      expect(canvas.y, closeTo(130, 0.01));
    });

    test('original mode divides by the device pixel ratio', () {
      // Without this the image renders at double size on a retina display.
      final canvas = CanvasModel();
      canvas.update(
        viewport: const Size(1920, 1080),
        display: display,
        style: kRemoteViewStyleOriginal,
        devicePixelRatio: 2,
      );

      expect(canvas.scale, 0.5);
    });

    test('custom mode applies the stored percent, then the pixel ratio', () {
      final canvas = CanvasModel();
      canvas.update(
        viewport: const Size(1920, 1080),
        display: display,
        style: kRemoteViewStyleCustom,
        customScale: 1.5,
        devicePixelRatio: 2,
      );

      expect(canvas.scale, closeTo(0.75, 0.0001));
    });

    test('overflow is reported when the image exceeds the viewport', () {
      final canvas = CanvasModel();
      canvas.update(
        viewport: const Size(800, 600),
        display: display,
        style: kRemoteViewStyleOriginal,
      );

      expect(canvas.isImageOverflow, isTrue);
    });

    test('changing the style resets scroll but resizing does not', () {
      final canvas = CanvasModel();
      canvas.update(
          viewport: const Size(800, 600),
          display: display,
          style: kRemoteViewStyleOriginal);
      canvas.setScroll(0.5, 0.5);

      canvas.update(
          viewport: const Size(900, 600),
          display: display,
          style: kRemoteViewStyleOriginal);
      expect(canvas.scrollX, 0.5, reason: 'a resize keeps the scroll position');

      canvas.update(
          viewport: const Size(900, 600),
          display: display,
          style: kRemoteViewStyleAdaptive);
      expect(canvas.scrollX, 0, reason: 'a style change resets scroll');
    });

    test('scroll offsets are clamped to 0..1', () {
      final canvas = CanvasModel();
      canvas.setScroll(-1, 5);

      expect(canvas.scrollX, 0);
      expect(canvas.scrollY, 1);
    });
  });

  group('remotePointFromLocal', () {
    const rect = Rect.fromLTWH(0, 0, 1920, 1080);

    test('maps 1:1 at scale 1 with no offset', () {
      final point = remotePointFromLocal(
        x: 100,
        y: 200,
        canvas: coords(),
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      expect(point, const Offset(100, 200));
    });

    test('undoes the canvas offset', () {
      // The image is centered, so a click at the image origin is at x=60.
      final point = remotePointFromLocal(
        x: 160,
        y: 100,
        canvas: coords(x: 60, y: 40),
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      expect(point, const Offset(100, 60));
    });

    test('divides by the scale', () {
      final point = remotePointFromLocal(
        x: 100,
        y: 100,
        canvas: coords(scale: 0.5),
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      expect(point, const Offset(200, 200));
    });

    test('offsets into a second monitor via the rect origin', () {
      // A multi-monitor peer's second display starts at x=1920.
      const second = Rect.fromLTWH(1920, 0, 1920, 1080);
      final point = remotePointFromLocal(
        x: 10,
        y: 10,
        canvas: coords(),
        rect: second,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      expect(point, const Offset(1930, 10));
    });

    test('a point outside the remote rect is rejected', () {
      final point = remotePointFromLocal(
        x: 5000,
        y: 5000,
        canvas: coords(),
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      expect(point, isNull);
    });

    test('a primary-button release outside the rect is still delivered', () {
      // Dropping it would leave the remote side with a stuck button.
      final point = remotePointFromLocal(
        x: 5000,
        y: 5000,
        canvas: coords(),
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeUp,
        buttons: kPrimaryMouseButton,
      );

      expect(point, isNotNull);
      expect(point!.dx, lessThanOrEqualTo(1920));
    });

    test('scrollbar mode applies the scroll fraction', () {
      final point = remotePointFromLocal(
        x: 0,
        y: 0,
        canvas: coords(
          size: const Size(960, 540),
          scale: 1.0,
          scrollX: 0.5,
          scrollY: 0.5,
          scrollStyle: ScrollStyle.scrollbar,
        ),
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      // Half of a 1920x1080 image scrolled past the origin.
      expect(point, const Offset(960, 540));
    });
  });

  group('pointInRemoteRect', () {
    const rect = Rect.fromLTWH(0, 0, 1920, 1080);

    test('Windows keeps the inclusive maximum for window snapping', () {
      // https://github.com/rustdesk/rustdesk/issues/6678
      final point = pointInRemoteRect(
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
        x: 1920,
        y: 1080,
        rect: rect,
      );

      expect(point, const Offset(1920, 1080));
    });

    test('other platforms stop one pixel short', () {
      final point = pointInRemoteRect(
        peerPlatform: PeerPlatform.linux,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
        x: 1920,
        y: 1080,
        rect: rect,
      );

      // 1920 is out of range on Linux, but within the snap threshold.
      expect(point, const Offset(1919, 1079));
    });

    test('a point just outside snaps back within the threshold', () {
      final point = pointInRemoteRect(
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
        x: -3,
        y: -2,
        rect: rect,
      );

      expect(point, const Offset(0, 0));
    });

    test('a point far outside is rejected', () {
      final point = pointInRemoteRect(
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
        x: -100,
        y: -100,
        rect: rect,
      );

      expect(point, isNull);
    });
  });

  group('nearestEdge', () {
    const rect = Rect.fromLTWH(0, 0, 1920, 1080);

    test('snaps to whichever border is closest', () {
      expect(nearestEdge(10, 500, rect).dx, 0);
      expect(nearestEdge(1910, 500, rect).dx, 1919);
      expect(nearestEdge(900, 5, rect).dy, 0);
      expect(nearestEdge(900, 1075, rect).dy, 1079);
    });
  });

  group('viewport fitted to the image', () {
    // Regression: the pointer region used to cover the whole viewport while
    // the image was letterboxed inside it, so every coordinate was offset by
    // the letterbox margin and clicks landed in the wrong place.
    const display = RemoteDisplay(width: 1920, height: 1080);
    const rect = Rect.fromLTWH(0, 0, 1920, 1080);

    test('a viewport matching the image leaves no offset', () {
      final canvas = CanvasModel();
      // 960x540 has the same 16:9 ratio as the display.
      canvas.update(
        viewport: const Size(960, 540),
        display: display,
        style: kRemoteViewStyleAdaptive,
      );

      expect(canvas.scale, closeTo(0.5, 0.0001));
      expect(canvas.x, closeTo(0, 0.0001));
      expect(canvas.y, closeTo(0, 0.0001));
    });

    test('the image corners map to the remote corners', () {
      final canvas = CanvasModel();
      canvas.update(
        viewport: const Size(960, 540),
        display: display,
        style: kRemoteViewStyleAdaptive,
      );

      final topLeft = remotePointFromLocal(
        x: 0,
        y: 0,
        canvas: canvas.coords,
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );
      expect(topLeft, const Offset(0, 0));

      final middle = remotePointFromLocal(
        x: 480,
        y: 270,
        canvas: canvas.coords,
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );
      expect(middle, const Offset(960, 540));
    });

    test('a letterboxed viewport still offsets, which is why the widget '
        'sizes the pointer region to the image', () {
      final canvas = CanvasModel();
      // A 4:3 viewport around a 16:9 image leaves margins above and below.
      canvas.update(
        viewport: const Size(960, 720),
        display: display,
        style: kRemoteViewStyleAdaptive,
      );

      expect(canvas.y, greaterThan(0));
      // Clicking the viewport's top-left is above the image, so it maps
      // outside the remote screen and is dropped.
      final outside = remotePointFromLocal(
        x: 0,
        y: 0,
        canvas: canvas.coords,
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );
      expect(outside, isNull);
    });
  });

  group('canvas and input share one geometry', () {
    // Regression: remoteRect used the decoded frame size while the canvas
    // scaled against the reported display. The two disagreed, so every
    // pointer position mapped outside the remote rect and was dropped —
    // clicks did nothing while the keyboard, which needs no coordinates,
    // kept working.
    test('a scale from the wrong geometry pushes clicks out of range', () {
      // The peer reports 2560x1600 but captures 1920x1080.
      const reported = RemoteDisplay(width: 2560, height: 1600);
      const frame = Rect.fromLTWH(0, 0, 1920, 1080);

      final wrong = CanvasModel()
        ..update(
          viewport: const Size(1920, 1080),
          display: reported,
          style: kRemoteViewStyleAdaptive,
        );

      // Clicking the middle of the image maps far right of where it should.
      final mapped = remotePointFromLocal(
        x: 960,
        y: 540,
        canvas: wrong.coords,
        rect: frame,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );
      // 960 maps to 1280 instead of 960: every coordinate is inflated by the
      // ratio between the two geometries, and points past the middle of the
      // image fall outside the 1920-wide rect entirely.
      expect(mapped, isNotNull);
      expect(mapped!.dx, greaterThan(1200),
          reason: 'the mismatch inflates every coordinate');

      final rightHalf = remotePointFromLocal(
        x: 1500,
        y: 540,
        canvas: wrong.coords,
        rect: frame,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );
      expect(rightHalf, isNull,
          reason: 'this is why clicks did nothing at all');
    });

    test('the same geometry on both sides maps the centre to the centre', () {
      const frame = Rect.fromLTWH(0, 0, 1920, 1080);
      final canvas = CanvasModel()
        ..update(
          viewport: const Size(1920, 1080),
          // Built from the frame rect, as updateViewport now does.
          display: const RemoteDisplay(width: 1920, height: 1080),
          style: kRemoteViewStyleAdaptive,
        );

      final mapped = remotePointFromLocal(
        x: 960,
        y: 540,
        canvas: canvas.coords,
        rect: frame,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      expect(mapped, const Offset(960, 540));
    });

    test('a click near the right edge stays inside the rect', () {
      const frame = Rect.fromLTWH(0, 0, 1920, 1080);
      final canvas = CanvasModel()
        ..update(
          viewport: const Size(960, 540),
          display: const RemoteDisplay(width: 1920, height: 1080),
          style: kRemoteViewStyleAdaptive,
        );

      final mapped = remotePointFromLocal(
        x: 959,
        y: 539,
        canvas: canvas.coords,
        rect: frame,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      // Reachable, not dropped.
      expect(mapped, isNotNull);
      expect(mapped!.dx, lessThanOrEqualTo(1920));
    });
  });

  group('updateFitted', () {
    // Regression: the widget fits and centres the image itself, but the model
    // was scaling by the view style on top of that. On a retina display the
    // original-size path applied 1/devicePixelRatio, so every coordinate came
    // out doubled and offset — clicks landed far from the pointer.
    const remote = Size(1920, 1080);
    const rect = Rect.fromLTWH(0, 0, 1920, 1080);

    test('a box the size of the image maps one to one', () {
      final canvas = CanvasModel()
        ..updateFitted(viewport: const Size(1920, 1080), remote: remote);

      expect(canvas.scale, 1.0);
      expect(canvas.x, 0);
      expect(canvas.y, 0);
    });

    test('a half-size box halves the scale with no offset', () {
      final canvas = CanvasModel()
        ..updateFitted(viewport: const Size(960, 540), remote: remote);

      expect(canvas.scale, closeTo(0.5, 0.0001));
      // No centring: the box already is the image.
      expect(canvas.x, 0);
      expect(canvas.y, 0);
    });

    test('the pointer maps to the same relative point', () {
      final canvas = CanvasModel()
        ..updateFitted(viewport: const Size(960, 540), remote: remote);

      // The centre of the box is the centre of the remote screen.
      expect(
        remotePointFromLocal(
          x: 480,
          y: 270,
          canvas: canvas.coords,
          rect: rect,
          peerPlatform: PeerPlatform.windows,
          kind: kPointerEventKindMouse,
          eventType: kMouseEventTypeMove,
        ),
        const Offset(960, 540),
      );

      // And the corners are reachable, not doubled out of range.
      expect(
        remotePointFromLocal(
          x: 0,
          y: 0,
          canvas: canvas.coords,
          rect: rect,
          peerPlatform: PeerPlatform.windows,
          kind: kPointerEventKindMouse,
          eventType: kMouseEventTypeMove,
        ),
        const Offset(0, 0),
      );
    });

    test('the observed doubling is gone', () {
      // From the real log: a click at local (367,359) in a 1920x1080 frame
      // mapped to remote (977,871) — roughly 2x plus an offset. With the box
      // sized to the image it maps to itself.
      final canvas = CanvasModel()
        ..updateFitted(viewport: const Size(1920, 1080), remote: remote);

      final mapped = remotePointFromLocal(
        x: 367,
        y: 359,
        canvas: canvas.coords,
        rect: rect,
        peerPlatform: PeerPlatform.windows,
        kind: kPointerEventKindMouse,
        eventType: kMouseEventTypeMove,
      );

      expect(mapped, const Offset(367, 359));
    });

    test('a zero remote size is ignored rather than dividing by zero', () {
      final canvas = CanvasModel()
        ..updateFitted(viewport: const Size(100, 100), remote: Size.zero);

      expect(canvas.scale, 1.0);
    });
  });
}
