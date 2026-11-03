import 'package:flutter/foundation.dart';
import 'package:flutter_gpu_texture_renderer/flutter_gpu_texture_renderer.dart';
import 'package:texture_rgba_renderer/texture_rgba_renderer.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

/// Which texture backs a display, and its current Flutter texture id.
///
/// The core decides per frame whether it delivers a GPU texture or a pixel
/// buffer, so both are registered up front and this switches between them.
class _DisplayTexture extends ChangeNotifier {
  int _rgbaTextureId = -1;
  int _gpuTextureId = -1;
  bool _isGpu = false;

  /// The id to hand to a `Texture` widget, or -1 when nothing is ready.
  int get textureId => _isGpu ? _gpuTextureId : _rgbaTextureId;

  bool get isGpu => _isGpu;

  bool get isReady => textureId != -1;

  void setType({required bool gpu}) {
    if (_isGpu == gpu) return;
    _isGpu = gpu;
    notifyListeners();
  }

  void setRgbaId(int id) {
    if (_rgbaTextureId == id) return;
    _rgbaTextureId = id;
    notifyListeners();
  }

  void setGpuId(int id) {
    if (_gpuTextureId == id) return;
    _gpuTextureId = id;
    notifyListeners();
  }
}

/// A pixel-buffer texture, written by the core through a raw pointer.
class _PixelbufferTexture {
  int _textureKey = -1;
  int _display = 0;
  UuidValue? _sessionId;
  bool _destroying = false;

  final _renderer = TextureRgbaRenderer();

  Future<void> create(
      int display, UuidValue sessionId, _DisplayTexture control) async {
    _display = display;
    _sessionId = sessionId;
    _textureKey = bind.getNextTextureKey();

    final id = await _renderer.createTexture(_textureKey);
    if (id == -1) {
      debugPrint('failed to create a pixelbuffer texture for display $display');
      return;
    }
    control.setRgbaId(id);
    final ptr = await _renderer.getTexturePtr(_textureKey);
    // Hand the core the pointer it writes frames into.
    platformFFI.registerPixelbufferTexture(sessionId, display, ptr);
    debugPrint('created pixelbuffer texture: display=$display, id=$id');
  }

  Future<void> destroy({required bool unregister}) async {
    if (_destroying || _textureKey == -1 || _sessionId == null) return;
    _destroying = true;
    if (unregister) {
      platformFFI.registerPixelbufferTexture(_sessionId!, _display, 0);
      // Give the core a moment to stop writing before the texture goes away;
      // rendering an unregistered texture crashes.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _renderer.closeTexture(_textureKey);
    _textureKey = -1;
    _destroying = false;
  }
}

/// A GPU texture, only available where the platform supports it.
class _GpuTexture {
  int _textureId = -1;
  int _display = 0;
  UuidValue? _sessionId;
  bool _destroying = false;

  final _renderer = FlutterGpuTextureRenderer();

  Future<void> create(
      int display, UuidValue sessionId, _DisplayTexture control) async {
    if (!bind.mainHasGpuTextureRender()) return;
    _display = display;
    _sessionId = sessionId;

    try {
      final id = await _renderer.registerTexture();
      if (id == null) return;
      _textureId = id;
      control.setGpuId(id);
      final output = await _renderer.output(id);
      if (output != null) {
        platformFFI.registerGpuTexture(sessionId, display, output);
      }
      debugPrint('created gpu texture: display=$display, id=$id');
    } catch (e) {
      debugPrint('failed to register a gpu texture: $e');
    }
  }

  Future<void> destroy({required bool unregister}) async {
    if (_destroying || _textureId == -1 || _sessionId == null) return;
    _destroying = true;
    if (unregister) {
      platformFFI.registerGpuTexture(_sessionId!, _display, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _renderer.unregisterTexture(_textureId);
    _textureId = -1;
    _destroying = false;
  }
}

/// Owns the render textures for one session.
///
/// Ported from `TextureModel` in
/// `flutter_legacy/lib/models/desktop_render_texture.dart`. One texture pair
/// per visible display; textures for displays that are no longer shown are
/// destroyed, because each one holds GPU memory the core writes into.
class TextureModel {
  TextureModel({required this.sessionId});

  final UuidValue sessionId;

  final Map<int, _DisplayTexture> _controls = {};
  final Map<int, _PixelbufferTexture> _pixelbuffers = {};
  final Map<int, _GpuTexture> _gpuTextures = {};

  /// Whether this build can render GPU textures at all.
  bool get supportsGpuTexture => bind.mainHasGpuTextureRender();

  _DisplayTexture _controlOf(int display) =>
      _controls.putIfAbsent(display, _DisplayTexture.new);

  /// Listenable texture id for [display].
  ///
  /// A `Texture` widget can watch this and rebuild on its own when the id
  /// changes, without rebuilding the whole session.
  ValueListenable<int> textureIdOf(int display) =>
      _TextureIdListenable(_controlOf(display));

  /// Whether [display] has a texture ready to render.
  bool isReady(int display) => _controlOf(display).isReady;

  /// The core reported which texture kind it will write for [display].
  void setTextureType({required int display, required bool gpuTexture}) {
    if (gpuTexture && !supportsGpuTexture) {
      debugPrint('the core offered a gpu texture but this build cannot render '
          'one; keeping the pixel buffer');
      return;
    }
    _controlOf(display).setType(gpu: gpuTexture);
  }

  /// Create textures for the displays currently shown and drop the rest.
  ///
  /// [currentDisplay] may be [kAllDisplayValue], which needs one texture per
  /// display in [peerInfo].
  Future<void> updateCurrentDisplay(int currentDisplay, PeerInfo peerInfo) async {
    if (currentDisplay == kAllDisplayValue) {
      final count = peerInfo.getCurDisplays().length;
      for (var i = 0; i < count; i++) {
        await _ensureTexture(i);
      }
      return;
    }

    await _ensureTexture(currentDisplay);
    // Free anything we are no longer showing.
    for (var i = 0; i < peerInfo.displays.length; i++) {
      if (i != currentDisplay) await _removeTexture(i);
    }
  }

  Future<void> _ensureTexture(int display) async {
    final control = _controlOf(display);
    if (!_pixelbuffers.containsKey(display)) {
      final texture = _PixelbufferTexture();
      _pixelbuffers[display] = texture;
      await texture.create(display, sessionId, control);
    }
    if (!_gpuTextures.containsKey(display) && supportsGpuTexture) {
      final texture = _GpuTexture();
      _gpuTextures[display] = texture;
      await texture.create(display, sessionId, control);
    }
  }

  Future<void> _removeTexture(int display) async {
    await _pixelbuffers.remove(display)?.destroy(unregister: true);
    await _gpuTextures.remove(display)?.destroy(unregister: true);
    _controls.remove(display)?.dispose();
  }

  /// Destroy every texture.
  ///
  /// [unregister] tells the core to stop writing first; pass false only when
  /// the session is already gone.
  Future<void> dispose({bool unregister = true}) async {
    for (final texture in _pixelbuffers.values) {
      await texture.destroy(unregister: unregister);
    }
    for (final texture in _gpuTextures.values) {
      await texture.destroy(unregister: unregister);
    }
    _pixelbuffers.clear();
    _gpuTextures.clear();
    for (final control in _controls.values) {
      control.dispose();
    }
    _controls.clear();
  }
}

/// Exposes a [_DisplayTexture]'s current id as a [ValueListenable].
class _TextureIdListenable extends ValueListenable<int> {
  _TextureIdListenable(this._control);

  final _DisplayTexture _control;

  @override
  int get value => _control.textureId;

  @override
  void addListener(VoidCallback listener) => _control.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _control.removeListener(listener);
}
