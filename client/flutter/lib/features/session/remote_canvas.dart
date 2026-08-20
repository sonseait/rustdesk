import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/features/session/session_view_model.dart';
import 'package:flutter_hbb/integration/session/canvas_model.dart';

/// The remote screen, rendered from the core's texture.
///
/// Replaces the placeholder canvas. The frames come from the native texture
/// the core writes into, so this widget only sizes it and routes input.
class RemoteCanvas extends StatefulWidget {
  const RemoteCanvas({super.key, required this.model});

  final SessionViewModel model;

  @override
  State<RemoteCanvas> createState() => _RemoteCanvasState();
}

class _RemoteCanvasState extends State<RemoteCanvas>
    with WidgetsBindingObserver {
  final _focusNode = FocusNode(debugLabel: 'remote canvas');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // macOS delivers focus events out of order around Space switches and
    // full-screen transitions, so a modifier held as the app goes inactive can
    // stay latched on the peer. Releasing on any non-resumed state is the
    // conservative half of the legacy latch machinery.
    if (state != AppLifecycleState.resumed) {
      widget.model.input.resetModifiers();
      widget.model.input.resetButtons();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    super.dispose();
  }

  SessionViewModel get _model => widget.model;

  @override
  Widget build(BuildContext context) {
    if (_model.stage != SessionStage.live) {
      return _SessionStatus(model: _model);
    }

    final remote = _model.remoteRect;
    if (remote.isEmpty) return const _WaitingForFrame();

    return LayoutBuilder(builder: (context, constraints) {
      // The image is letterboxed inside the viewport, so input has to be
      // measured against the image, not the whole area. Sizing the pointer
      // region to the fitted rect makes localPosition start at the image's
      // top-left corner, which is the frame the coordinate transform expects.
      final fitted = _fitRect(constraints.biggest, remote);
      final ratio = MediaQuery.devicePixelRatioOf(context);
      // Geometry has to be recomputed after layout, not during it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _model.updateViewport(fitted, devicePixelRatio: ratio);
        }
      });

      return Focus(
        focusNode: _focusNode,
        autofocus: true,
        // The canvas owns the keyboard while it has focus, so keys reach the
        // peer instead of triggering local shortcuts.
        onKeyEvent: (_, event) => _model.handleKeyEvent(event),
        onFocusChange: (hasFocus) {
          // A modifier held while focus moves away would stick on the peer.
          if (!hasFocus) _model.input.resetModifiers();
        },
        child: Center(
          child: SizedBox(
            width: fitted.width,
            height: fitted.height,
            child: MouseRegion(
              onExit: (event) {
                _model.input.resetButtons();
                _model.sendPointer(
                  type: kMouseEventTypeMove,
                  local: event.localPosition,
                  onExit: true,
                );
              },
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerHover: _onPointerHover,
                onPointerSignal: _onPointerSignal,
                child: _TextureView(model: _model),
              ),
            ),
          ),
        ),
      );
    });
  }

  /// The largest rect with [remote]'s aspect ratio that fits in [available].
  static Size _fitRect(Size available, Rect remote) {
    if (remote.width <= 0 || remote.height <= 0) return available;
    final scale = math.min(
      available.width / remote.width,
      available.height / remote.height,
    );
    return Size(remote.width * scale, remote.height * scale);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _focusNode.requestFocus();
    final resolved =
        _model.input.resolvePointer(event, kMouseEventTypeDown);
    _model.sendPointer(
      type: resolved.type,
      local: event.localPosition,
      buttons: resolved.buttons,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final resolved =
        _model.input.resolvePointer(event, kMouseEventTypeMove);
    _model.sendPointer(
      type: resolved.type,
      local: event.localPosition,
      buttons: resolved.buttons,
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final resolved = _model.input.resolvePointer(event, kMouseEventTypeUp);
    _model.sendPointer(
      type: resolved.type,
      local: event.localPosition,
      buttons: resolved.buttons,
    );
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _model.sendPointer(
      type: kMouseEventTypeMove,
      local: event.localPosition,
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // The core takes wheel notches, not pixels.
    final dy = event.scrollDelta.dy;
    final dx = event.scrollDelta.dx;
    _model.scroll(
      dy == 0 ? 0 : (dy > 0 ? -1 : 1),
      x: dx == 0 ? 0 : (dx > 0 ? -1 : 1),
    );
  }
}

/// Renders the remote frames, from whichever path the core is using.
///
/// The core picks per session: a native texture (default on Windows/Linux,
/// opt-in on macOS via `use-texture-render`) or raw RGBA frames Flutter
/// decodes. Both have to render, or the canvas is black on one of them.
class _TextureView extends StatelessWidget {
  const _TextureView({required this.model});

  final SessionViewModel model;

  @override
  Widget build(BuildContext context) {
    final remote = model.remoteRect;
    if (remote.isEmpty) return const SizedBox.expand();

    // The decoded-image path: the core sends pixels, not a texture.
    if (!model.usesTextureRender) {
      final image = model.images.image;
      if (image == null) return const _WaitingForFrame();
      // The parent sized this to the image's aspect ratio already, so fill it.
      return RawImage(
        image: image,
        fit: BoxFit.fill,
        // Frames arrive continuously; filtering every one is wasted work and
        // softens text on the remote screen.
        filterQuality: FilterQuality.none,
      );
    }

    return ValueListenableBuilder<int>(
      valueListenable: model.textures.textureIdOf(model.currentDisplay),
      builder: (context, textureId, _) {
        if (textureId == -1) return const _WaitingForFrame();
        return Texture(textureId: textureId);
      },
    );
  }
}

/// Shown between "connected" and the first frame.
///
/// A static panel rather than a spinner: the canvas already showed a
/// "Connecting" state, and a perpetual animation never lets a frame settle.
class _WaitingForFrame extends StatelessWidget {
  const _WaitingForFrame();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0xFF17110F),
        child: Center(
          child: Text(
            'Waiting for the first frame…',
            style: TextStyle(color: Color(0xFFD9C3B9), fontSize: 12),
          ),
        ),
      );
}

/// Connecting, prompt, closed and failure states.
class _SessionStatus extends StatelessWidget {
  const _SessionStatus({required this.model});

  final SessionViewModel model;

  @override
  Widget build(BuildContext context) {
    final (icon, title) = switch (model.stage) {
      SessionStage.connecting => (LucideIcons.loaderCircle, 'Connecting'),
      SessionStage.prompt => (LucideIcons.lock, 'Authentication required'),
      SessionStage.closed => (LucideIcons.circleOff, 'Session closed'),
      SessionStage.failed => (LucideIcons.triangleAlert, 'Connection failed'),
      SessionStage.live => (LucideIcons.monitor, 'Connected'),
    };

    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
              color: Color(0xFF3B241C), shape: BoxShape.circle),
          child: Icon(icon, size: 34, color: const Color(0xFFF5B69B)),
        ),
        const SizedBox(height: 15),
        Text(title,
            style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            model.statusLine,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFD9C3B9), fontSize: 12),
          ),
        ),
        if (model.stage == SessionStage.failed ||
            model.stage == SessionStage.closed) ...[
          const SizedBox(height: 16),
          CupertinoButton(
            color: const Color(0xFF8C402A),
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            minimumSize: Size.zero,
            onPressed: () => model.reconnect(),
            child: const Text('Reconnect', style: TextStyle(fontSize: 13)),
          ),
        ],
        if (model.stage == SessionStage.prompt) ...[
          const SizedBox(height: 16),
          _PasswordPrompt(model: model),
        ],
      ]),
    );
  }
}

/// Collects the credential the core asked for.
class _PasswordPrompt extends StatefulWidget {
  const _PasswordPrompt({required this.model});

  final SessionViewModel model;

  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _controller = TextEditingController();
  var _remember = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isTwoFactor => widget.model.prompt?.type == 'input-2fa';

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 280,
        child: Column(children: [
          CupertinoTextField(
            controller: _controller,
            autofocus: true,
            obscureText: !_isTwoFactor,
            placeholder: _isTwoFactor ? 'Two-factor code' : 'Password',
            placeholderStyle: const TextStyle(color: Color(0xFF8D766D)),
            style: const TextStyle(color: CupertinoColors.white),
            padding:
                const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            decoration: BoxDecoration(
                color: const Color(0xFF2A1C17),
                border: Border.all(color: const Color(0xFF604033)),
                borderRadius: BorderRadius.circular(9)),
            onSubmitted: (_) => _submit(),
          ),
          if (!_isTwoFactor) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => setState(() => _remember = !_remember),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                    _remember
                        ? LucideIcons.squareCheck
                        : LucideIcons.square,
                    size: 15,
                    color: const Color(0xFFD9C3B9)),
                const SizedBox(width: 7),
                const Text('Remember this password',
                    style: TextStyle(color: Color(0xFFD9C3B9), fontSize: 12)),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          CupertinoButton(
            color: const Color(0xFF8C402A),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            minimumSize: Size.zero,
            onPressed: _submit,
            child: const Text('Connect', style: TextStyle(fontSize: 13)),
          ),
        ]),
      );

  void _submit() {
    final value = _controller.text;
    if (value.isEmpty) return;
    if (_isTwoFactor) {
      widget.model.submitTwoFactor(value);
    } else {
      widget.model.submitPassword(value, remember: _remember);
    }
    _controller.clear();
  }
}
