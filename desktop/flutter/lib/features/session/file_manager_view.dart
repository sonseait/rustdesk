import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/integration/session/file_models.dart';
import 'package:flutter_hbb/integration/session/file_transfer_adapter.dart';

/// The two-pane file manager.
///
/// Left is this machine, right is the peer. Transfers move between them, and
/// the queue along the bottom shows progress for anything in flight.
class FileManagerView extends StatefulWidget {
  const FileManagerView({super.key, required this.adapter});

  final FileTransferAdapter adapter;

  @override
  State<FileManagerView> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _selected = <FileSide, Set<String>>{
    FileSide.local: {},
    FileSide.remote: {},
  };

  @override
  void initState() {
    super.initState();
    widget.adapter.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.adapter.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.adapter.overwriteRequest;
    return Stack(children: [
      Column(children: [
        Expanded(
          child: Row(children: [
            Expanded(child: _pane(FileSide.local)),
            _TransferControls(
              onSendRight: () => _transfer(FileSide.local),
              onSendLeft: () => _transfer(FileSide.remote),
              canSendRight: _selected[FileSide.local]!.isNotEmpty,
              canSendLeft: _selected[FileSide.remote]!.isNotEmpty,
            ),
            Expanded(child: _pane(FileSide.remote)),
          ]),
        ),
        if (widget.adapter.jobs.isNotEmpty)
          _TransferQueue(
            jobs: widget.adapter.jobs,
            onCancel: widget.adapter.cancel,
            onClear: widget.adapter.clearFinishedJobs,
          ),
      ]),
      // The core blocks the transfer until this is answered.
      if (request != null)
        _OverwriteDialog(
          request: request,
          onAnswer: (overwrite, remember) => widget.adapter
              .answerOverwrite(overwrite: overwrite, remember: remember),
        ),
    ]);
  }

  Widget _pane(FileSide side) => _FilePaneView(
        pane: widget.adapter.paneOf(side),
        selected: _selected[side]!,
        onToggleSelect: (entry) => setState(() {
          final set = _selected[side]!;
          if (!set.remove(entry.path)) set.add(entry.path);
        }),
        onOpen: (entry) {
          setState(() => _selected[side]!.clear());
          widget.adapter.paneOf(side).openDirectory(entry.path);
        },
        onDelete: (entry) => _confirmDelete(entry, side),
      );

  void _transfer(FileSide from) {
    final pane = widget.adapter.paneOf(from);
    final chosen = pane.entries
        .where((e) => _selected[from]!.contains(e.path))
        .toList();
    if (chosen.isEmpty) return;
    widget.adapter.transfer(chosen, from);
    setState(() => _selected[from]!.clear());
  }

  Future<void> _confirmDelete(FileEntry entry, FileSide side) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(entry.isDirectory
            ? 'This deletes the folder and everything inside it.'
            : 'This cannot be undone.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.adapter.remove(entry, side);
    }
  }
}

/// One side of the manager: breadcrumb, listing, and per-row actions.
class _FilePaneView extends StatelessWidget {
  const _FilePaneView({
    required this.pane,
    required this.selected,
    required this.onToggleSelect,
    required this.onOpen,
    required this.onDelete,
  });

  final FilePane pane;
  final Set<String> selected;
  final ValueChanged<FileEntry> onToggleSelect;
  final ValueChanged<FileEntry> onOpen;
  final ValueChanged<FileEntry> onDelete;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF211613),
          border: Border.all(color: const Color(0xFF4A3029)),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Column(children: [
          _Breadcrumb(pane: pane),
          const ColoredBox(
              color: Color(0xFF4A3029),
              child: SizedBox(height: 1, width: double.infinity)),
          Expanded(child: _listing(context)),
        ]),
      );

  Widget _listing(BuildContext context) {
    if (pane.isLoading && pane.entries.isEmpty) {
      return const _PaneMessage(text: 'Loading…');
    }
    if (pane.error != null) {
      return _PaneMessage(text: 'Could not read this folder\n${pane.error}');
    }
    if (pane.entries.isEmpty) {
      return const _PaneMessage(text: 'This folder is empty');
    }
    return ListView.builder(
      itemCount: pane.entries.length,
      itemBuilder: (context, index) {
        final entry = pane.entries[index];
        return _FileRow(
          entry: entry,
          isSelected: selected.contains(entry.path),
          onTap: () => onToggleSelect(entry),
          onOpen: entry.isDirectory || entry.isDrive
              ? () => onOpen(entry)
              : null,
          onDelete: () => onDelete(entry),
        );
      },
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.pane});

  final FilePane pane;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          Icon(
              pane.side == FileSide.local
                  ? LucideIcons.hardDrive
                  : LucideIcons.monitor,
              size: 14,
              color: const Color(0xFFF5B69B)),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              pane.path.isEmpty ? '…' : pane.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ),
          _PaneButton(
              icon: LucideIcons.arrowUp, onTap: pane.goUp, tooltip: 'Up'),
          _PaneButton(
              icon: LucideIcons.refreshCw,
              onTap: () => pane.openDirectory(),
              tooltip: 'Refresh'),
        ]),
      );
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.entry,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
    this.onOpen,
  });

  final FileEntry entry;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        onDoubleTap: onOpen,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          color: isSelected
              ? const Color(0xFF8C402A).withValues(alpha: .3)
              : CupertinoColors.transparent,
          child: Row(children: [
            Icon(
                entry.isDirectory || entry.isDrive
                    ? LucideIcons.folder
                    : LucideIcons.file,
                size: 14,
                color: const Color(0xFFD9C3B9)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: CupertinoColors.white, fontSize: 11)),
            ),
            if (entry.isFile)
              Text(readableFileSize(entry.size),
                  style: const TextStyle(
                      color: Color(0xFF9C8279), fontSize: 10)),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onDelete,
              child: const Icon(LucideIcons.trash2,
                  size: 13, color: Color(0xFF9C8279)),
            ),
          ]),
        ),
      );
}

/// The arrows between the panes.
class _TransferControls extends StatelessWidget {
  const _TransferControls({
    required this.onSendRight,
    required this.onSendLeft,
    required this.canSendRight,
    required this.canSendLeft,
  });

  final VoidCallback onSendRight;
  final VoidCallback onSendLeft;
  final bool canSendRight;
  final bool canSendLeft;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PaneButton(
              icon: LucideIcons.arrowRight,
              onTap: canSendRight ? onSendRight : null,
              tooltip: 'Send to the remote device'),
          const SizedBox(height: 10),
          _PaneButton(
              icon: LucideIcons.arrowLeft,
              onTap: canSendLeft ? onSendLeft : null,
              tooltip: 'Bring to this device'),
        ],
      );
}

/// Transfers in flight and recently finished.
class _TransferQueue extends StatelessWidget {
  const _TransferQueue({
    required this.jobs,
    required this.onCancel,
    required this.onClear,
  });

  final List<FileJob> jobs;
  final ValueChanged<int> onCancel;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(maxHeight: 132),
        decoration: const BoxDecoration(
          color: Color(0xFF1B1211),
          border: Border(top: BorderSide(color: Color(0xFF4A3029))),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
            child: Row(children: [
              const Expanded(
                child: Text('Transfers',
                    style: TextStyle(
                        color: CupertinoColors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
              GestureDetector(
                onTap: onClear,
                child: const Text('Clear finished',
                    style: TextStyle(color: Color(0xFFF0AB90), fontSize: 10)),
              ),
            ]),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: jobs.length,
              itemBuilder: (context, index) =>
                  _JobRow(job: jobs[index], onCancel: onCancel),
            ),
          ),
        ]),
      );
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.onCancel});

  final FileJob job;
  final ValueChanged<int> onCancel;

  String get _status {
    if (job.wasCancelled) return 'Cancelled';
    if (job.wasSkipped) return 'Skipped';
    switch (job.state) {
      case JobState.done:
        return 'Done';
      case JobState.error:
        return job.error.isEmpty ? 'Failed' : 'Failed: ${job.error}';
      case JobState.paused:
        return 'Paused';
      case JobState.inProgress:
        return '${job.percentText} · '
            '${job.handledFileCount}/${job.fileCount} files';
      case JobState.none:
        return 'Waiting';
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(children: [
          Icon(
              job.isRemoteToLocal
                  ? LucideIcons.arrowLeft
                  : LucideIcons.arrowRight,
              size: 12,
              color: const Color(0xFF9C8279)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(job.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: CupertinoColors.white, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text(_status,
                      style: const TextStyle(
                          color: Color(0xFF9C8279), fontSize: 10)),
                ]),
          ),
          if (!job.isFinished)
            GestureDetector(
              onTap: () => onCancel(job.id),
              child: const Icon(LucideIcons.x,
                  size: 13, color: Color(0xFF9C8279)),
            ),
        ]),
      );
}

/// Asks whether to replace an existing file.
class _OverwriteDialog extends StatefulWidget {
  const _OverwriteDialog({required this.request, required this.onAnswer});

  final OverwriteRequest request;
  final void Function(bool overwrite, bool remember) onAnswer;

  @override
  State<_OverwriteDialog> createState() => _OverwriteDialogState();
}

class _OverwriteDialogState extends State<_OverwriteDialog> {
  var _remember = false;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: CupertinoColors.black.withValues(alpha: .55),
        child: Center(
          child: Container(
            width: 320,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF2B1C17),
              border: Border.all(color: const Color(0xFF694337)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('File already exists',
                  style: TextStyle(
                      color: CupertinoColors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(widget.request.path,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Color(0xFFD9C3B9), fontSize: 11)),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => setState(() => _remember = !_remember),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      _remember
                          ? LucideIcons.squareCheck
                          : LucideIcons.square,
                      size: 14,
                      color: const Color(0xFFD9C3B9)),
                  const SizedBox(width: 6),
                  const Text('Apply to the rest of this transfer',
                      style:
                          TextStyle(color: Color(0xFFD9C3B9), fontSize: 11)),
                ]),
              ),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 7),
                  minimumSize: Size.zero,
                  onPressed: () => widget.onAnswer(false, _remember),
                  child: const Text('Skip',
                      style: TextStyle(
                          color: Color(0xFFD9C3B9), fontSize: 12)),
                ),
                const SizedBox(width: 8),
                CupertinoButton(
                  color: const Color(0xFF8C402A),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 7),
                  minimumSize: Size.zero,
                  onPressed: () => widget.onAnswer(true, _remember),
                  child: const Text('Replace',
                      style: TextStyle(fontSize: 12)),
                ),
              ]),
            ]),
          ),
        ),
      );
}

class _PaneButton extends StatelessWidget {
  const _PaneButton({required this.icon, this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF3B241C),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(icon,
            size: 13,
            color: onTap == null
                ? const Color(0xFF6B564E)
                : const Color(0xFFF5DDD2)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: tooltip == null
          ? button
          : Semantics(label: tooltip, button: true, child: button),
    );
  }
}

class _PaneMessage extends StatelessWidget {
  const _PaneMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9C8279), fontSize: 11)),
        ),
      );
}
