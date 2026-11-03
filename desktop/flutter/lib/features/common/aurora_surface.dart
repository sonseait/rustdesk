import 'package:flutter/cupertino.dart';

/// The corner radius of an Aurora panel. The hover overlay must match it, or
/// the highlight corners sit proud of the surface underneath.
const double kPanelRadius = 15;

class HoverTap extends StatefulWidget {
  const HoverTap({
    this.onTap,
    this.onTapAt,
    required this.child,
    this.radius = kPanelRadius,
  }) : assert(onTap != null || onTapAt != null, 'needs a tap handler');

  final VoidCallback? onTap;

  /// Receives the pointer position, for callers that open a menu there.
  final ValueChanged<Offset>? onTapAt;

  final Widget child;

  /// Must match the radius of the surface being hovered.
  final double radius;

  @override
  State<HoverTap> createState() => _HoverTapState();
}

class _HoverTapState extends State<HoverTap> {
  var _hovered = false;
  Offset _lastTapPosition = Offset.zero;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTapDown: (details) => _lastTapPosition = details.globalPosition,
          onTap: () {
            widget.onTap?.call();
            widget.onTapAt?.call(_lastTapPosition);
          },
          child: Stack(fit: StackFit.passthrough, children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 130),
                  decoration: BoxDecoration(
                    color: _hovered
                        ? CupertinoColors.black.withValues(alpha: .055)
                        : CupertinoColors.transparent,
                    borderRadius: BorderRadius.circular(widget.radius),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}

BoxDecoration panelDecoration(BuildContext context) {
  final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
      color: (dark ? const Color(0xFF261B17) : CupertinoColors.white)
          .withValues(alpha: .78),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(
          color: (dark ? const Color(0xFF71483B) : const Color(0xFFE7C9BB))
              .withValues(alpha: .68)),
      boxShadow: [
        BoxShadow(
            color: CupertinoColors.black.withValues(alpha: dark ? .14 : .055),
            blurRadius: 22,
            offset: const Offset(0, 9))
      ]);
}

