import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';

import 'package:flutter_hbb/integration/session/terminal_model.dart';

/// Remote shells, one per tab.
class TerminalToolView extends StatefulWidget {
  const TerminalToolView({super.key, required this.registry});

  final TerminalRegistry registry;

  @override
  State<TerminalToolView> createState() => _TerminalToolViewState();
}

class _TerminalToolViewState extends State<TerminalToolView> {
  int _active = 0;

  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_onChanged);
    // Open the first shell as soon as the tool is shown.
    if (widget.registry.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.registry.openTerminal();
      });
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.registry.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final terminals = widget.registry.terminals;
    if (terminals.isEmpty) {
      return const Center(
        child: Text('Starting a shell…',
            style: TextStyle(color: Color(0xFFD9C3B9), fontSize: 12)),
      );
    }
    final index = _active.clamp(0, terminals.length - 1);
    return Column(children: [
      _TerminalTabs(
        terminals: terminals,
        active: index,
        onSelect: (i) => setState(() => _active = i),
        onOpen: () => widget.registry.openTerminal(),
        onClose: (id) => widget.registry.closeTerminal(id),
      ),
      Expanded(child: _TerminalPane(model: terminals[index])),
    ]);
  }
}

class _TerminalTabs extends StatelessWidget {
  const _TerminalTabs({
    required this.terminals,
    required this.active,
    required this.onSelect,
    required this.onOpen,
    required this.onClose,
  });

  final List<TerminalModel> terminals;
  final int active;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpen;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: const BoxDecoration(
          color: Color(0xFF1B1211),
          border: Border(bottom: BorderSide(color: Color(0xFF4A3029))),
        ),
        child: Row(children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: terminals.length,
              itemBuilder: (context, index) {
                final isActive = index == active;
                return GestureDetector(
                  onTap: () => onSelect(index),
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 2, vertical: 5),
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isActive
                          ? const Color(0xFF3B241C)
                          : CupertinoColors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('Shell ${index + 1}',
                          style: TextStyle(
                              color: isActive
                                  ? CupertinoColors.white
                                  : const Color(0xFF9C8279),
                              fontSize: 11,
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.w400)),
                      if (terminals.length > 1) ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => onClose(terminals[index].terminalId),
                          child: const Icon(LucideIcons.x,
                              size: 11, color: Color(0xFF9C8279)),
                        ),
                      ],
                    ]),
                  ),
                );
              },
            ),
          ),
          GestureDetector(
            onTap: onOpen,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(LucideIcons.plus, size: 14, color: Color(0xFFF5DDD2)),
            ),
          ),
        ]),
      );
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({required this.model});

  final TerminalModel model;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  @override
  void initState() {
    super.initState();
    // Output buffered before layout can be written once the view exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.model.markViewReady();
    });
  }

  @override
  void didUpdateWidget(_TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.model.markViewReady();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.model.error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(LucideIcons.triangleAlert,
                size: 26, color: Color(0xFFF5B69B)),
            const SizedBox(height: 10),
            const Text('Terminal unavailable',
                style: TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(error,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Color(0xFFD9C3B9), fontSize: 11)),
          ]),
        ),
      );
    }

    return ColoredBox(
      color: const Color(0xFF17110F),
      child: TerminalView(
        widget.model.terminal,
        theme: _auroraTheme,
        padding: const EdgeInsets.all(10),
        autofocus: true,
      ),
    );
  }
}

/// Terminal colors matching the Aurora dark surface.
const _auroraTheme = TerminalTheme(
  cursor: Color(0xFFF5B69B),
  selection: Color(0x558C402A),
  foreground: Color(0xFFF6E9E2),
  background: Color(0xFF17110F),
  black: Color(0xFF2A1C17),
  red: Color(0xFFE86A5A),
  green: Color(0xFF8FBF6F),
  yellow: Color(0xFFE0B25F),
  blue: Color(0xFF7FA9D6),
  magenta: Color(0xFFC98BC0),
  cyan: Color(0xFF6FBFB4),
  white: Color(0xFFF6E9E2),
  brightBlack: Color(0xFF6B564E),
  brightRed: Color(0xFFFF8A78),
  brightGreen: Color(0xFFA9D98A),
  brightYellow: Color(0xFFF5CC7A),
  brightBlue: Color(0xFF9CC3E8),
  brightMagenta: Color(0xFFE0A6D8),
  brightCyan: Color(0xFF8FD9CE),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFF8C402A),
  searchHitBackgroundCurrent: Color(0xFFB55433),
  searchHitForeground: Color(0xFFFFFFFF),
);
