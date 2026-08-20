import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

/// Decoded remote frames, for the pixel-buffer render path.
///
/// Ported from `ImageModel` in `flutter_legacy/lib/models/model.dart`. The core
/// picks between two render paths per session:
///
/// - **texture**: the core writes into a native texture and Flutter only shows
///   a `Texture` widget. Opt-in on macOS (`use-texture-render`), default on
///   Windows and Linux.
/// - **RGBA**: the core hands Flutter raw pixels for every frame, which this
///   model decodes into a `ui.Image`.
///
/// Both must work — a session that only handles textures renders nothing on a
/// default macOS build.
class ImageModel extends ChangeNotifier {
  ImageModel({required this.sessionId, void Function(int display)? onFrameDone})
      : _onFrameDone = onFrameDone;

  final UuidValue sessionId;

  /// Acknowledges a consumed frame. Overridable so tests can decode without a
  /// native bridge; production always acknowledges through the core.
  final void Function(int display)? _onFrameDone;

  void _frameDone(int display) {
    final override = _onFrameDone;
    if (override != null) {
      override(display);
      return;
    }
    platformFFI.nextRgba(sessionId, display);
  }

  ui.Image? _image;
  (int, int)? _frameSize;
  bool _decoding = false;
  bool _disposed = false;

  /// The most recent decoded frame, or null before the first one arrives.
  ui.Image? get image => _image;

  /// The geometry the peer is actually capturing at, once a frame has been
  /// decoded. The canvas sizes itself from this rather than the reported
  /// display, so the aspect ratio and pointer mapping match the pixels.
  (int, int)? get frameSize => _frameSize;

  bool get hasImage => _image != null;

  /// Handle one RGBA frame from the core.
  ///
  /// The core blocks until the frame is acknowledged with `nextRgba`, so that
  /// call has to happen on every path, including failures — otherwise the
  /// stream stalls after exactly one frame.
  Future<void> onRgba(int display, Uint8List rgba, PeerInfo peerInfo) async {
    if (_disposed) {
      _frameDone(display);
      return;
    }
    // Drop frames that arrive while one is still decoding rather than queueing
    // them; the newest frame is the only one worth showing.
    if (_decoding) {
      _frameDone(display);
      return;
    }
    _decoding = true;
    try {
      await _decodeAndUpdate(display, rgba, peerInfo);
    } catch (e) {
      debugPrint('failed to decode an rgba frame: $e');
    } finally {
      _decoding = false;
      _frameDone(display);
    }
  }

  Future<void> _decodeAndUpdate(
      int display, Uint8List rgba, PeerInfo peerInfo) async {
    final target = peerInfo.tryGetDisplay(display: display);
    if (target == null) return;

    // The buffer carries no dimensions, and neither reported size is reliable:
    // a scaled peer sends frames at `original_*` on one session and at
    // `width`/`height` on the next, depending on what it is capturing. Pick
    // whichever candidate the buffer length actually matches rather than
    // trusting one of them.
    final size = _sizeForBuffer(rgba.lengthInBytes, target);
    if (size == null) {
      debugPrint('no reported size matches a ${rgba.lengthInBytes}-byte frame '
          '(${target.width}x${target.height}, original '
          '${target.originalWidth}x${target.originalHeight}); dropping');
      return;
    }
    final width = size.$1;
    final height = size.$2;
    _frameSize = size;

    final image = await _decodePixels(rgba, width, height);
    if (image == null) return;
    if (_disposed) {
      image.dispose();
      return;
    }
    _setImage(image);
  }

  /// The reported size whose pixel count matches [bytes], or null.
  ///
  /// A display reports two candidate geometries and the peer may capture at
  /// either one, so this resolves the ambiguity from the frame itself.
  static (int, int)? _sizeForBuffer(int bytes, RemoteDisplay display) {
    if (bytes <= 0 || bytes % 4 != 0) return null;
    final candidates = <(int, int)>[
      (display.width, display.height),
      if (display.isOriginalResolutionSet)
        (display.originalWidth, display.originalHeight),
    ];
    for (final candidate in candidates) {
      if (candidate.$1 <= 0 || candidate.$2 <= 0) continue;
      if (candidate.$1 * candidate.$2 * 4 == bytes) return candidate;
    }
    return null;
  }

  Future<ui.Image?> _decodePixels(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      // The core packs pixels differently per platform; using the wrong order
      // renders the image with red and blue swapped.
      (isWindows || isLinux || isWeb)
          ? ui.PixelFormat.rgba8888
          : ui.PixelFormat.bgra8888,
      completer.complete,
    );
    return completer.future;
  }

  void _setImage(ui.Image image) {
    // Release the frame being replaced; these are large native buffers.
    _image?.dispose();
    _image = image;
    notifyListeners();
  }

  /// Drop the current frame, e.g. when the session closes.
  void clear() {
    _image?.dispose();
    _image = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
