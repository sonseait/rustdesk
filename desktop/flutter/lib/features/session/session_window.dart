import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/integration/platform/host_platform.dart';

import 'package:flutter_hbb/features/session/session_page.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/session_tabs_model.dart';

/// A desktop session window holding one or more sessions as tabs.
///
/// A second connection into an already-open window arrives as a multi-window
/// method call rather than a new process, so this listens for those events and
/// adds a tab. Each tab keeps its own [SessionPage] — and so its own FFI
/// session — alive while it is in the background, because closing it would
/// drop the connection.
class SessionWindow extends StatefulWidget {
  const SessionWindow({
    super.key,
    required this.tabs,
    this.options,
    this.onLastTabClosed,
    this.pageBuilder,
  });

  /// The sessions this window holds. Owned by the caller so the window
  /// bootstrap can seed it from the launch arguments.
  final SessionTabsModel tabs;

  /// Injectable for tests.
  final OptionRepository? options;

  /// Called when the final tab closes, so the shell can close the window.
  final VoidCallback? onLastTabClosed;

  /// Builds a tab's surface. Injectable for tests, which have no native
  /// bridge to start a real session against.
  final Widget Function(SessionTab)? pageBuilder;

  @override
  State<SessionWindow> createState() => SessionWindowState();
}

class SessionWindowState extends State<SessionWindow> with WindowListener {
  OptionRepository get _options => widget.options ?? OptionRepository.instance;

  var _listening = false;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    widget.tabs.addListener(_onTabsChanged);
    if (isDesktop) {
      // The title-bar close button has to be intercepted, or it would drop
      // every live session in the window without asking.
      windowManager.addListener(this);
      _listening = true;
      unawaited(windowManager.setPreventClose(true));
    }
  }

  void _onTabsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.tabs.removeListener(_onTabsChanged);
    if (_listening) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() => unawaited(_handleWindowClose());

  /// Close the window, once the user has confirmed dropping its sessions.
  ///
  /// The real close comes back through this same callback, so the flag stays
  /// set once closing is under way; clearing it would show a second dialog.
  /// A cancelled close does clear it, or the button would stop working.
  Future<void> _handleWindowClose() async {
    if (_closing) return;
    _closing = true;
    if (!await confirmCloseAll()) {
      _closing = false;
      return;
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  /// Whether closing several sessions at once should be confirmed first.
  ///
  /// One tab closes without asking: the user is closing the session they are
  /// looking at. Several is a whole window of live connections, which the
  /// existing option guards.
  bool get needsCloseConfirmation =>
      widget.tabs.length > 1 &&
      _options.getLocalBool(kOptionEnableConfirmClosingTabs);

  /// Ask about closing every session, and close them if the user agrees.
  ///
  /// Returns true when the window may close. Called by the shell for the
  /// window's own close button, so a stray click does not drop several live
  /// connections.
  Future<bool> confirmCloseAll() async {
    if (!needsCloseConfirmation) {
      widget.tabs.closeAll();
      return true;
    }
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => _CloseAllDialog(
        count: widget.tabs.length,
        onKeepAsking: (value) =>
            _options.setLocalBool(kOptionEnableConfirmClosingTabs, value),
      ),
    );
    if (confirmed != true) return false;
    widget.tabs.closeAll();
    return true;
  }

  void _closeTab(String peerId) {
    widget.tabs.close(peerId);
    if (widget.tabs.isEmpty) widget.onLastTabClosed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs.tabs;
    if (tabs.isEmpty) {
      return const CupertinoPageScaffold(
        backgroundColor: Color(0xFF17110F),
        child: Center(
            child: Text('No session open',
                style: TextStyle(color: Color(0xFFB9A69E), fontSize: 13))),
      );
    }

    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF17110F),
      child: Column(children: [
        // One session needs no tab strip; showing a single tab would be
        // chrome that says nothing.
        if (tabs.length > 1)
          SafeArea(
            bottom: false,
            child: _TabStrip(
                tabs: tabs,
                selected: widget.tabs.selectedIndex,
                onSelected: widget.tabs.select,
                onClose: _closeTab),
          ),
        Expanded(
          // Every tab stays built: disposing a background tab would close its
          // FFI session and drop the connection.
          child: IndexedStack(
            index: widget.tabs.selectedIndex,
            children: [
              for (final tab in tabs)
                widget.pageBuilder?.call(tab) ??
                    SessionPage(
                      key: ValueKey(tab.key),
                      remoteId: tab.peerId,
                      password: tab.password,
                      kind: tab.kind,
                      forceRelay: tab.forceRelay,
                      isSharedPassword: tab.isSharedPassword,
                      connToken: tab.connToken,
                      switchUuid: tab.switchUuid,
                      initialMode: modeOf(tab.kind),
                    )
            ],
          ),
        ),
      ]),
    );
  }

  /// The session page's tool index for a connection kind.
  static int modeOf(ConnectionKind kind) => switch (kind) {
        ConnectionKind.fileTransfer => 1,
        ConnectionKind.terminal => 2,
        ConnectionKind.portForward || ConnectionKind.rdp => 3,
        ConnectionKind.remoteDesktop || ConnectionKind.viewCamera => 0,
      };
}

/// The row of open sessions.
class _TabStrip extends StatelessWidget {
  const _TabStrip(
      {required this.tabs,
      required this.selected,
      required this.onSelected,
      required this.onClose});

  final List<SessionTab> tabs;
  final int selected;
  final ValueChanged<int> onSelected;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) => Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(color: Color(0xFF211714)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (var index = 0; index < tabs.length; index++)
              _Tab(
                  tab: tabs[index],
                  isSelected: index == selected,
                  onTap: () => onSelected(index),
                  onClose: () => onClose(tabs[index].peerId)),
          ]),
        ),
      );
}

class _Tab extends StatelessWidget {
  const _Tab(
      {required this.tab,
      required this.isSelected,
      required this.onTap,
      required this.onClose});

  final SessionTab tab;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
          padding: const EdgeInsets.only(left: 10, right: 5),
          decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF3A2620)
                  : CupertinoColors.transparent,
              borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_iconOf(tab.kind),
                size: 13,
                color: isSelected
                    ? const Color(0xFFF3E3DB)
                    : const Color(0xFF9C8880)),
            const SizedBox(width: 7),
            Text(tab.peerId,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? const Color(0xFFF3E3DB)
                        : const Color(0xFF9C8880))),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onClose,
              child: const Padding(
                  padding: EdgeInsets.all(5),
                  child:
                      Icon(LucideIcons.x, size: 12, color: Color(0xFF9C8880))),
            ),
          ]),
        ),
      );

  static IconData _iconOf(ConnectionKind kind) => switch (kind) {
        ConnectionKind.remoteDesktop => LucideIcons.monitor,
        ConnectionKind.fileTransfer => LucideIcons.folderOpen,
        ConnectionKind.viewCamera => LucideIcons.camera,
        ConnectionKind.portForward || ConnectionKind.rdp => LucideIcons.share2,
        ConnectionKind.terminal => LucideIcons.terminal,
      };
}

/// Asks before dropping several live connections at once.
class _CloseAllDialog extends StatefulWidget {
  const _CloseAllDialog({required this.count, required this.onKeepAsking});

  final int count;

  /// Records whether to ask again, so the answer sticks across windows.
  final ValueChanged<bool> onKeepAsking;

  @override
  State<_CloseAllDialog> createState() => _CloseAllDialogState();
}

class _CloseAllDialogState extends State<_CloseAllDialog> {
  var _keepAsking = true;

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
        title: const Text('Disconnect all devices?'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(children: [
            Text('${widget.count} sessions are open in this window.'),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => setState(() => _keepAsking = !_keepAsking),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_keepAsking ? LucideIcons.squareCheck : LucideIcons.square,
                    size: 16),
                const SizedBox(width: 8),
                const Flexible(
                    child: Text('Ask before closing multiple sessions',
                        style: TextStyle(fontSize: 12))),
              ]),
            ),
          ]),
        ),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              widget.onKeepAsking(_keepAsking);
              Navigator.pop(context, true);
            },
            child: const Text('Disconnect'),
          ),
        ],
      );
}
