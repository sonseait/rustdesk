import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_hbb/integration/adapters/managed_client_adapter.dart';

class ManagedDiagnosticsPage extends StatefulWidget {
  const ManagedDiagnosticsPage({super.key, required this.adapter});
  final ManagedClientAdapter adapter;

  @override
  State<ManagedDiagnosticsPage> createState() => _ManagedDiagnosticsPageState();
}

class _ManagedDiagnosticsPageState extends State<ManagedDiagnosticsPage> {
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    widget.adapter.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.adapter.refresh();
    });
  }

  void _changed() {
    if (mounted) setState(() => _copied = false);
  }

  @override
  void dispose() {
    widget.adapter.removeListener(_changed);
    super.dispose();
  }

  String get _report => 'Managed diagnostics\n\n${widget.adapter.diagnosticSummary}'
      '\n\nStatus history (UTC, current app session only)\n'
      '${widget.adapter.diagnosticEvents.join('\n\n')}';

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _report));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
                title: const Text('Copy unavailable'),
                content: const Text('Select the diagnostic text to copy it manually.'),
                actions: [CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              ));
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: const Text('Diagnostics'),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _copy,
            child: Text(_copied ? 'Copied' : 'Copy'),
          ),
        ),
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text('Managed readiness is not the hbbs Online status. '
                'This view shows managed status changes, not the complete native application log.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            SelectableText(widget.adapter.diagnosticSummary,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 20),
            const Text('Status history', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('UTC • Latest first • Up to 100 changes • Cleared on app restart',
                style: TextStyle(fontSize: 11)),
            const SizedBox(height: 8),
            if (widget.adapter.diagnosticEvents.isEmpty)
              const Text('No status changes recorded yet.', style: TextStyle(fontSize: 12)),
            for (final event in widget.adapter.diagnosticEvents)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: SelectableText(event,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
          ]),
        ),
      );
}
