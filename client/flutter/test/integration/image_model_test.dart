import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/integration/session/image_model.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

import 'peer_info_test.dart' show display, peerInfoEvent;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Frame acknowledgement goes through the native bridge in production; the
  /// tests record it instead.
  final acknowledged = <int>[];
  ImageModel model() => ImageModel(
        sessionId: const Uuid().v4obj(),
        onFrameDone: acknowledged.add,
      );

  group('frame state', () {
    test('starts with no image', () {
      final images = model();

      expect(images.image, isNull);
      expect(images.hasImage, isFalse);
    });

    test('clear is safe before any frame arrives', () {
      expect(model().clear, returnsNormally);
    });

    test('dispose is safe before any frame arrives', () {
      expect(model().dispose, returnsNormally);
    });
  });

  group('decode guards', () {
    // These paths must not throw, because the core blocks on the frame
    // acknowledgement: an exception that skips nextRgba stalls the stream
    // after exactly one frame.
    final peerInfo =
        PeerInfo.fromEvent(peerInfoEvent(displays: [display()]));

    test('an undersized buffer does not throw', () async {
      // A truncated frame would otherwise blow up inside the decoder.
      final images = model();

      await expectLater(
        images.onRgba(0, Uint8List(16), peerInfo),
        completes,
      );
    });

    // Frames for unknown displays and post-dispose frames are also handled,
    // but both acknowledge through the native bridge, so they are covered by
    // the live session rather than here.
  });

  group('decoding a real frame', () {
    final peerInfo = PeerInfo.fromEvent(
        peerInfoEvent(displays: [display(width: 2, height: 2)]));

    test('produces an image sized to the remote display', () async {
      // Four opaque pixels, which is a valid frame for a 2x2 display.
      final rgba = Uint8List.fromList([
        for (var i = 0; i < 4; i++) ...[0x10, 0x20, 0x30, 0xFF],
      ]);
      final images = model();

      await images.onRgba(0, rgba, peerInfo);

      expect(images.hasImage, isTrue);
      expect(images.image!.width, 2);
      expect(images.image!.height, 2);
    });

    test('a later frame replaces the earlier one', () async {
      final rgba = Uint8List.fromList([
        for (var i = 0; i < 4; i++) ...[0, 0, 0, 0xFF],
      ]);
      final images = model();

      await images.onRgba(0, rgba, peerInfo);
      final first = images.image;
      await images.onRgba(0, rgba, peerInfo);

      expect(images.image, isNot(same(first)),
          reason: 'each frame is a new image');
    });

    test('clear drops the frame', () async {
      final rgba = Uint8List.fromList([
        for (var i = 0; i < 4; i++) ...[0, 0, 0, 0xFF],
      ]);
      final images = model();
      await images.onRgba(0, rgba, peerInfo);
      expect(images.hasImage, isTrue);

      images.clear();

      expect(images.hasImage, isFalse);
    });
  });

  group('choosing the frame geometry', () {
    // Regression: a scaled peer sent 1920x1080 frames on one session and
    // 2560x1600 on the next, so trusting either reported size alone dropped
    // every frame on the other one.
    const scaled = RemoteDisplay(
      width: 2560,
      height: 1600,
      originalWidth: 1920,
      originalHeight: 1080,
    );

    test('decodes a frame that matches the reported size', () async {
      final images = model();
      final rgba = Uint8List(2560 * 1600 * 4);

      await images.onRgba(
          0,
          rgba,
          PeerInfo.fromEvent(peerInfoEvent(displays: [
            display(
                width: 2560,
                height: 1600,
                originalWidth: 1920,
                originalHeight: 1080)
          ])));

      expect(images.hasImage, isTrue);
      expect(images.frameSize, (2560, 1600));
    });

    test('decodes a frame that matches the original size instead', () async {
      final images = model();
      final rgba = Uint8List(1920 * 1080 * 4);

      await images.onRgba(
          0,
          rgba,
          PeerInfo.fromEvent(peerInfoEvent(displays: [
            display(
                width: 2560,
                height: 1600,
                originalWidth: 1920,
                originalHeight: 1080)
          ])));

      expect(images.hasImage, isTrue);
      // The same display, a different capture size, both decode.
      expect(images.frameSize, (1920, 1080));
    });

    test('a buffer matching neither candidate is dropped', () async {
      final images = model();
      final rgba = Uint8List(1280 * 720 * 4);

      await images.onRgba(
          0,
          rgba,
          PeerInfo.fromEvent(peerInfoEvent(displays: [
            display(
                width: 2560,
                height: 1600,
                originalWidth: 1920,
                originalHeight: 1080)
          ])));

      // Decoding at a guessed size would tear the image.
      expect(images.hasImage, isFalse);
      expect(images.frameSize, isNull);
    });

    test('an unscaled display still decodes', () async {
      final images = model();
      final rgba = Uint8List(1920 * 1080 * 4);

      await images.onRgba(0, rgba,
          PeerInfo.fromEvent(peerInfoEvent(displays: [display()])));

      expect(images.hasImage, isTrue);
      expect(images.frameSize, (1920, 1080));
    });

    test('the scaled display from the real log is covered', () {
      expect(scaled.isScaled, isTrue);
      expect(scaled.width * scaled.height * 4, 16384000);
      expect(scaled.originalWidth * scaled.originalHeight * 4, 8294400);
    });
  });
}
