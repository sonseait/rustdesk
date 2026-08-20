import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/routing/window_coordinator.dart';
import 'package:flutter_hbb/integration/routing/window_frame_store.dart';

/// Keeps a window's saved frame up to date.
///
/// A window is moved and resized far more often than it is closed, so the
/// writes are debounced: without that, dragging a window across the screen
/// would write to the config on every frame. The final position is flushed
/// immediately on close, since a debounced write would never run.
///
/// Wrap the window's surface with this. On a platform without windows it is
/// transparent and does nothing.
class WindowFrameKeeper extends StatefulWidget {
  const WindowFrameKeeper({
    super.key,
    required this.type,
    required this.child,
    this.windowId,
    this.peerId,
    this.coordinator,
  });

  /// Which window this is. [WindowType.Main] uses `window_manager`; anything
  /// else is a sub window addressed by [windowId].
  final WindowType type;

  /// Required for a sub window: its frame cannot be read without it.
  final int? windowId;

  /// The peer this window serves, so its frame is also saved against that
  /// peer. Null for the main window.
  final String? peerId;

  final Widget child;

  /// Injectable for tests.
  final WindowCoordinator? coordinator;

  @override
  State<WindowFrameKeeper> createState() => _WindowFrameKeeperState();
}

class _WindowFrameKeeperState extends State<WindowFrameKeeper>
    with WindowListener {
  Timer? _debounce;
  WindowFrame? _pending;
  var _listening = false;

  static const _debounceDelay = Duration(seconds: 1);

  WindowCoordinator get _coordinator =>
      widget.coordinator ?? WindowCoordinator.instance;

  bool get _isSubWindow => widget.type != WindowType.Main;

  @override
  void initState() {
    super.initState();
    if (!isDesktop) return;
    // Sub windows get these callbacks too — the legacy tab bar registers the
    // same listener in every window — so both kinds are tracked here and only
    // the frame is read differently.
    windowManager.addListener(this);
    _listening = true;
  }

  @override
  void dispose() {
    // A pending write would be lost; the window is going away, so flush it.
    unawaited(_flush());
    _debounce?.cancel();
    if (_listening) windowManager.removeListener(this);
    super.dispose();
  }

  // ---------------------------------------------------------------- reading

  /// The window's current frame, or null when it cannot be read.
  ///
  /// A maximised or fullscreen window reports the screen's size rather than
  /// the size it would return to, so only the flags are recorded and the saved
  /// size is left alone.
  Future<WindowFrame?> _readFrame() async {
    try {
      if (_isSubWindow) {
        final windowId = widget.windowId;
        if (windowId == null) return null;
        final controller = WindowController.fromWindowId(windowId);
        final isMaximized = await controller.isMaximized();
        final isFullscreen = await controller.isFullScreen();
        if (isMaximized || isFullscreen) {
          return _flagsOnly(isMaximized, isFullscreen);
        }
        final frame = await controller.getFrame();
        return WindowFrame(
          width: frame.width,
          height: frame.height,
          offsetWidth: frame.left,
          offsetHeight: frame.top,
          isMaximized: false,
          isFullscreen: false,
        );
      }

      final isMaximized = await windowManager.isMaximized();
      final isFullscreen = await windowManager.isFullScreen();
      if (isMaximized || isFullscreen) {
        return _flagsOnly(isMaximized, isFullscreen);
      }
      final position = await windowManager.getPosition();
      final size = await windowManager.getSize();
      return WindowFrame(
        width: size.width,
        height: size.height,
        offsetWidth: position.dx,
        offsetHeight: position.dy,
        isMaximized: false,
        isFullscreen: false,
      );
    } catch (e) {
      // A hidden window has no frame to read; that is not an error worth
      // surfacing, and there is nothing new to save.
      debugPrint('failed to read the frame of ${widget.type.name}: $e');
      return null;
    }
  }

  /// The saved frame with only the maximised/fullscreen flags updated.
  WindowFrame _flagsOnly(bool isMaximized, bool isFullscreen) {
    final saved = WindowFrameStore.instance.frameOf(widget.type);
    return WindowFrame(
      width: saved?.width,
      height: saved?.height,
      offsetWidth: saved?.offsetWidth,
      offsetHeight: saved?.offsetHeight,
      isMaximized: isMaximized,
      isFullscreen: isFullscreen,
    );
  }

  // ---------------------------------------------------------------- writing

  void _scheduleSave() {
    if (!isDesktop) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => unawaited(_save()));
  }

  Future<void> _save() async {
    final frame = await _readFrame();
    if (frame == null || frame == _pending) return;
    _pending = frame;
    await _coordinator.saveFrame(widget.type, frame,
        windowId: widget.windowId, peerId: widget.peerId);
  }

  /// Write immediately, cancelling any debounced write.
  Future<void> _flush() async {
    if (!isDesktop) return;
    _debounce?.cancel();
    await _save();
  }

  /// Save the current frame now. Call this before closing a window.
  Future<void> flush() => _flush();

  // ------------------------------------------------------- window callbacks

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  void onWindowEnterFullScreen() => _scheduleSave();

  @override
  void onWindowLeaveFullScreen() => _scheduleSave();

  @override
  void onWindowClose() => unawaited(_flush());

  @override
  Widget build(BuildContext context) => widget.child;
}
