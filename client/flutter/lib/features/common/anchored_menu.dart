import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/features/common/aurora_surface.dart';

/// One row in an anchored dropdown.
class MenuAction {
  const MenuAction({
    required this.label,
    required this.onTap,
    this.icon,
    this.isDestructive = false,
    this.isSelected = false,
  });

  /// Leading icon. Omit it in a menu of switches, where the trailing check is
  /// what carries the state.
  final IconData? icon;

  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  /// Draws a trailing check, for menus that show state rather than fire an
  /// action: a sort key, a view style, an on/off switch.
  final bool isSelected;
}

/// A dropdown that opens at the pointer, clamped to the screen.
///
/// `CompositedTransformFollower` anchors to the trigger's box, which for a
/// small icon inside a tall row leaves the menu visibly detached. This instead
/// positions the menu at the click point and measures the available space, so
/// it never floats away from the cursor, never runs off an edge, and flips
/// above the pointer when there is not enough room below.
class AnchoredMenu extends StatefulWidget {
  const AnchoredMenu({
    required this.actions,
    required this.builder,
    this.width = 190,
  });

  final List<MenuAction> actions;

  /// Builds the trigger. [open] takes the pointer position in global
  /// coordinates; pass null to open at the trigger's bottom-right corner.
  final Widget Function(BuildContext context, void Function([Offset?]) open)
      builder;
  final double width;

  @override
  State<AnchoredMenu> createState() => _AnchoredMenuState();
}

class _AnchoredMenuState extends State<AnchoredMenu> {
  OverlayEntry? _overlay;

  /// Height of one menu row: 15px icon/12px text plus 8px padding each side.
  static const double _rowHeight = 31;
  static const double _menuPadding = 5;
  static const double _screenMargin = 8;
  static const double _pointerGap = 4;

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _toggle);

  void _toggle([Offset? globalPosition]) {
    if (_overlay != null) {
      _removeOverlay();
      return;
    }
    final origin = globalPosition ?? _triggerCorner();
    if (origin == null) return;

    // Actions are read when the overlay builds, not when it was created, so a
    // menu reopened after a state change shows the new labels and checks.
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlaySize =
        (overlay.context.findRenderObject() as RenderBox?)?.size ??
            MediaQuery.sizeOf(context);
    final menuHeight =
        widget.actions.length * _rowHeight + _menuPadding * 2;


    // Prefer below-right of the pointer; flip when it would overflow.
    var left = origin.dx;
    if (left + widget.width + _screenMargin > overlaySize.width) {
      left = origin.dx - widget.width;
    }
    left = left.clamp(
        _screenMargin, (overlaySize.width - widget.width - _screenMargin)
            .clamp(_screenMargin, double.infinity));

    var top = origin.dy + _pointerGap;
    if (top + menuHeight + _screenMargin > overlaySize.height) {
      // Not enough room below: place it above the pointer instead.
      top = origin.dy - menuHeight - _pointerGap;
    }
    top = top.clamp(
        _screenMargin, (overlaySize.height - menuHeight - _screenMargin)
            .clamp(_screenMargin, double.infinity));

    _overlay = OverlayEntry(
        builder: (context) => Stack(children: [
              // Tapping anywhere outside dismisses the menu.
              Positioned.fill(
                  child: GestureDetector(
                      onTap: _toggle, behavior: HitTestBehavior.translucent)),
              Positioned(
                  left: left,
                  top: top,
                  width: widget.width,
                  child: Container(
                      padding: const EdgeInsets.all(_menuPadding),
                      decoration: panelDecoration(context),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final action in widget.actions)
                              _AnchoredMenuRow(
                                  action: action,
                                  onTap: () {
                                    _removeOverlay();
                                    action.onTap();
                                  })
                          ]))),
            ]));
    overlay.insert(_overlay!);
  }

  /// The trigger's bottom-right corner, for keyboard or programmatic opens
  /// where there is no pointer position.
  Offset? _triggerCorner() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset(box.size.width, box.size.height));
  }
}

/// A hover-highlighted trigger that reports where the pointer went down, so
/// [AnchoredMenu] can open exactly there.
///
/// A nested [GestureDetector] would win the gesture arena over [HoverTap]'s
/// own, so the position is threaded through [HoverTap.onTapAt] instead.
class MenuTrigger extends StatelessWidget {
  const MenuTrigger({
    required this.open,
    required this.child,
    this.radius = 7,
  });

  final void Function([Offset?]) open;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => HoverTap(
        radius: radius,
        onTapAt: (position) => open(position),
        child: child,
      );
}

class _AnchoredMenuRow extends StatefulWidget {
  const _AnchoredMenuRow({required this.action, required this.onTap});
  final MenuAction action;
  final VoidCallback onTap;

  @override
  State<_AnchoredMenuRow> createState() => _AnchoredMenuRowState();
}

class _AnchoredMenuRowState extends State<_AnchoredMenuRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final destructive = widget.action.isDestructive;
    final color = destructive ? CupertinoColors.systemRed : null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
              // Hover changes the background only.
              color: _hovered
                  ? CupertinoTheme.of(context)
                      .primaryColor
                      .withValues(alpha: .1)
                  : null,
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            if (widget.action.icon != null) ...[
              Icon(widget.action.icon, size: 15, color: color),
              const SizedBox(width: 9),
            ],
            Expanded(
                child: Text(widget.action.label,
                    style: TextStyle(fontSize: 12, color: color))),
            if (widget.action.isSelected) ...[
              const SizedBox(width: 8),
              Icon(LucideIcons.check, size: 14, color: color),
            ],
          ]),
        ),
      ),
    );
  }
}
