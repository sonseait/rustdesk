import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/features/common/anchored_menu.dart';
import 'package:flutter_hbb/features/session/chat_panel.dart';
import 'package:flutter_hbb/features/session/file_manager_view.dart';
import 'package:flutter_hbb/features/session/port_forward_view.dart';
import 'package:flutter_hbb/features/session/remote_canvas.dart';
import 'package:flutter_hbb/features/session/terminal_view.dart';
import 'package:flutter_hbb/features/session/session_view_model.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/session/session_options.dart';

class SessionPage extends StatefulWidget {
  const SessionPage({
    super.key,
    required this.remoteId,
    this.initialMode = 0,
    this.viewModel,
    this.password,
    this.kind = ConnectionKind.remoteDesktop,
    this.forceRelay = false,
    this.isSharedPassword,
    this.connToken,
    this.switchUuid,
  });

  final String remoteId;
  final int initialMode;

  /// Injectable for tests. Defaults to a model over a live session.
  final SessionViewModel? viewModel;

  /// Password to try on connect, when the caller already has one.
  final String? password;
  final ConnectionKind kind;
  final bool forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final String? switchUuid;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  late int _mode;
  late final SessionViewModel _model;
  late final bool _ownsModel;
  var _toolbarVisible = true;
  var _detailsVisible = false;
  var _chatVisible = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode.clamp(0, 3);
    _ownsModel = widget.viewModel == null;
    _model = widget.viewModel ??
        SessionViewModel(peerId: widget.remoteId, kind: widget.kind);
    _model.addListener(_onModelChanged);
    _model.start(
      password: widget.password,
      forceRelay: widget.forceRelay,
      isSharedPassword: widget.isSharedPassword ?? false,
      connToken: widget.connToken,
      switchUuid: widget.switchUuid ?? '',
    );
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    // The session must be closed or the core leaks it.
    if (_ownsModel) _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        backgroundColor: const Color(0xFF17110F),
        child: SafeArea(
          child: Stack(children: [
            Positioned.fill(
                child: Row(children: [
              Expanded(
                  child: Padding(
                      // The toolbar floats at top: 14 and is ~43px tall,
                      // so the tools need clearance or it covers their
                      // first row of controls.
                      padding: EdgeInsets.fromLTRB(
                          20, _toolbarVisible ? 70 : 20, 20, 20),
                      child: _Canvas(
                          mode: _mode,
                          remoteId: widget.remoteId,
                          model: _model))),
              if (_chatVisible)
                ChatPanel(
                    chat: _model.chat,
                    onClose: () => setState(() => _chatVisible = false)),
            ])),
            if (_toolbarVisible)
              Positioned(
                  top: 14,
                  left: 16,
                  right: 16,
                  child: _Toolbar(
                      remoteId: widget.remoteId,
                      mode: _mode,
                      model: _model,
                      onModeChanged: (mode) => setState(() => _mode = mode),
                      onChat: () =>
                          setState(() => _chatVisible = !_chatVisible),
                      chatVisible: _chatVisible,
                      onDetails: () =>
                          setState(() => _detailsVisible = !_detailsVisible),
                      onClose: () => Navigator.pop(context))),
            if (_detailsVisible)
              Positioned(
                  top: 77,
                  right: 24,
                  child: _SessionDetails(
                      remoteId: widget.remoteId, mode: _mode, model: _model)),
            Positioned(
                right: 20,
                bottom: 20,
                child: GestureDetector(
                    onTap: () =>
                        setState(() => _toolbarVisible = !_toolbarVisible),
                    child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: const Color(0xFFF5DDD2),
                            borderRadius: BorderRadius.circular(10)),
                        child: Icon(
                            _toolbarVisible
                                ? LucideIcons.eyeOff
                                : LucideIcons.eye,
                            size: 17,
                            color: const Color(0xFF542719))))),
          ]),
        ),
      );
}

class _Toolbar extends StatelessWidget {
  const _Toolbar(
      {required this.remoteId,
      required this.mode,
      required this.model,
      required this.onModeChanged,
      required this.onChat,
      required this.chatVisible,
      required this.onDetails,
      required this.onClose});
  final String remoteId;
  final int mode;
  final SessionViewModel model;
  final ValueChanged<int> onModeChanged;
  final VoidCallback onChat;
  final bool chatVisible;
  final VoidCallback onDetails;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
            color: const Color(0xED261916),
            border: Border.all(color: const Color(0xFF694337)),
            borderRadius: BorderRadius.circular(13)),
        child: Row(children: [
          _ToolbarButton(icon: LucideIcons.x, onTap: onClose),
          const SizedBox(width: 7),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Text(
                    model.peerInfo.hostname.isEmpty
                        ? remoteId
                        : '${model.peerInfo.hostname} · $remoteId',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: CupertinoColors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                // Real connection state, not an assumption.
                Text(model.statusLine,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Color(0xFFF0AB90), fontSize: 10))
              ])),
          if (model.isMultiDisplay) ...[
            _DisplayPicker(model: model),
            const SizedBox(width: 6),
          ],
          if (model.stage == SessionStage.live) ...[
            _ChatButton(
                unread: model.unreadChatCount,
                active: chatVisible,
                onTap: onChat),
            const SizedBox(width: 6),
            _ToolbarButton(
                icon: model.isViewOnly
                    ? LucideIcons.eyeOff
                    : LucideIcons.mousePointer2,
                active: model.isViewOnly,
                onTap: () => model.setViewOnly(!model.isViewOnly)),
            const SizedBox(width: 6),
            _ViewStyleButton(model: model),
            const SizedBox(width: 6),
            _SessionOptionsButton(model: model),
            const SizedBox(width: 6),
          ],
          _ModeControl(value: mode, onChanged: onModeChanged),
          const SizedBox(width: 6),
          _ToolbarButton(icon: LucideIcons.info, onTap: onDetails),
        ]),
      );
}

/// The tool surface: remote desktop, files, or a terminal.
class _Canvas extends StatelessWidget {
  const _Canvas(
      {required this.mode, required this.remoteId, required this.model});
  final int mode;
  final String remoteId;
  final SessionViewModel model;

  @override
  Widget build(BuildContext context) => Center(
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1450, maxHeight: 900),
          child: Container(
              decoration: BoxDecoration(
                  color: const Color(0xFF211613),
                  border: Border.all(color: const Color(0xFF604033)),
                  borderRadius: BorderRadius.circular(18)),
              // Clip inside the border rather than on the Container itself:
              // a tool that paints its own background to the edge (the
              // terminal's tab strip) would otherwise square off the corners.
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: switch (mode) {
                    0 => RemoteCanvas(model: model),
                    1 => _Files(model: model),
                    2 => _Terminal(model: model),
                    _ => _Tunnels(model: model)
                  }))));
}

/// A tool that needs a live session before it can show anything.
class _ToolPlaceholder extends StatelessWidget {
  const _ToolPlaceholder(
      {required this.icon, required this.title, required this.status});
  final IconData icon;
  final String title;
  final String status;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: const Color(0xFFF5B69B), size: 40),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFD9C3B9), fontSize: 12)),
        ]),
      );
}

class _Files extends StatelessWidget {
  const _Files({required this.model});
  final SessionViewModel model;

  @override
  Widget build(BuildContext context) {
    // File transfer needs a live session to list the remote side.
    if (model.stage != SessionStage.live) {
      return _ToolPlaceholder(
          icon: LucideIcons.folder, title: 'Files', status: model.statusLine);
    }
    return FileManagerView(adapter: model.files);
  }
}

class _Tunnels extends StatelessWidget {
  const _Tunnels({required this.model});
  final SessionViewModel model;

  @override
  Widget build(BuildContext context) {
    // Tunnels are created on the peer, so the session has to be up.
    if (model.stage != SessionStage.live) {
      return _ToolPlaceholder(
          icon: LucideIcons.route,
          title: 'Port forwarding',
          status: model.statusLine);
    }
    return PortForwardView(model: model.portForwards);
  }
}

class _Terminal extends StatelessWidget {
  const _Terminal({required this.model});
  final SessionViewModel model;

  @override
  Widget build(BuildContext context) {
    // A shell needs a live session to run in.
    if (model.stage != SessionStage.live) {
      return _ToolPlaceholder(
          icon: LucideIcons.terminal,
          title: 'Terminal',
          status: model.statusLine);
    }
    return TerminalToolView(registry: model.terminals);
  }
}

/// Switches between the remote desktop, files and terminal.
class _ModeControl extends StatelessWidget {
  const _ModeControl({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  static const _modes = [
    (LucideIcons.monitor, 'Desktop'),
    (LucideIcons.folder, 'Files'),
    (LucideIcons.terminal, 'Terminal'),
    (LucideIcons.route, 'Tunnels'),
  ];

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: const Color(0xFF3B241C).withValues(alpha: .55),
            borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < _modes.length; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                    color: value == i
                        ? const Color(0xFF8C402A)
                        : CupertinoColors.transparent,
                    borderRadius: BorderRadius.circular(7)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_modes[i].$1, size: 14, color: const Color(0xFFF5DDD2)),
                  const SizedBox(width: 5),
                  Text(_modes[i].$2,
                      style: TextStyle(
                          color: const Color(0xFFF5DDD2),
                          fontSize: 11,
                          fontWeight:
                              value == i ? FontWeight.w700 : FontWeight.w500)),
                ]),
              ),
            ),
        ]),
      );
}

/// What the peer reported about itself and this connection.
class _SessionDetails extends StatelessWidget {
  const _SessionDetails(
      {required this.remoteId, required this.mode, required this.model});
  final String remoteId;
  final int mode;
  final SessionViewModel model;

  @override
  Widget build(BuildContext context) => Container(
        width: 248,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: const Color(0xF0261916),
            border: Border.all(color: const Color(0xFF694337)),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                  color: CupertinoColors.black.withValues(alpha: .22),
                  blurRadius: 20,
                  offset: const Offset(0, 9))
            ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Session details',
              style: TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 13),
          _DetailRow(label: 'Endpoint', value: remoteId),
          _DetailRow(
              label: 'Mode',
              value: switch (mode) {
                0 => 'Desktop',
                1 => 'Files',
                2 => 'Terminal',
                _ => 'Tunnels'
              }),
          // Everything below is reported by the peer, not assumed.
          if (model.peerInfo.hostname.isNotEmpty)
            _DetailRow(label: 'Host', value: model.peerInfo.hostname),
          if (model.peerInfo.platform.isNotEmpty)
            _DetailRow(label: 'Platform', value: model.peerInfo.platform),
          if (model.peerInfo.username.isNotEmpty)
            _DetailRow(label: 'User', value: model.peerInfo.username),
          _DetailRow(
              label: 'Security',
              value: model.isSecure ? 'Encrypted' : 'Not encrypted'),
          _DetailRow(
              label: 'Route', value: model.isDirect ? 'Direct' : 'Relayed'),
          if (model.displays.isNotEmpty)
            _DetailRow(
                label: 'Display',
                value: model.currentDisplay == kAllDisplayValue
                    ? 'All (${model.displays.length})'
                    : '${model.currentDisplay + 1} of '
                        '${model.displays.length}'),
          _DetailRow(
              label: 'Input',
              value: model.canSendInput ? 'Enabled' : 'View only'),
        ]),
      );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style:
                      const TextStyle(color: Color(0xFF9C8279), fontSize: 11))),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}

/// Switches which remote display is shown.
class _DisplayPicker extends StatelessWidget {
  const _DisplayPicker({required this.model});
  final SessionViewModel model;

  @override
  Widget build(BuildContext context) => AnchoredMenu(
        width: 208,
        actions: [
          for (var i = 0; i < model.displays.length; i++)
            MenuAction(
              label: 'Display ${i + 1} · '
                  '${model.displays[i].width}x${model.displays[i].height}',
              isSelected: model.currentDisplay == i,
              onTap: () => model.switchDisplay(i),
            ),
          MenuAction(
            label: 'All displays',
            isSelected: model.currentDisplay == kAllDisplayValue,
            onTap: () => model.switchDisplay(kAllDisplayValue),
          ),
        ],
        builder: (context, open) => MenuTrigger(
          open: open,
          child: const Padding(
            padding: EdgeInsets.all(7),
            child: Icon(LucideIcons.monitorSmartphone,
                size: 15, color: Color(0xFFF5DDD2)),
          ),
        ),
      );
}

/// Chooses how the remote image is fitted.
class _ViewStyleButton extends StatelessWidget {
  const _ViewStyleButton({required this.model});
  final SessionViewModel model;

  static const _styles = [
    (kRemoteViewStyleAdaptive, 'Fit to window'),
    (kRemoteViewStyleOriginal, 'Original size'),
  ];

  @override
  Widget build(BuildContext context) => AnchoredMenu(
        width: 186,
        actions: [
          for (final style in _styles)
            MenuAction(
              label: style.$2,
              isSelected: model.viewStyle == style.$1,
              onTap: () => model.setViewStyle(style.$1),
            ),
        ],
        builder: (context, open) => MenuTrigger(
          open: open,
          child: const Padding(
            padding: EdgeInsets.all(7),
            child:
                Icon(LucideIcons.scaling, size: 15, color: Color(0xFFF5DDD2)),
          ),
        ),
      );
}

/// Clipboard, audio, recording and the other per-session switches.
class _SessionOptionsButton extends StatelessWidget {
  const _SessionOptionsButton({required this.model});

  final SessionViewModel model;

  /// The switches the toolbar offers, in menu order.
  static const _toggles = [
    (SessionToggle.disableAudio, 'Audio'),
    (SessionToggle.disableClipboard, 'Clipboard'),
    (SessionToggle.fileCopyPaste, 'Copy and paste files'),
    (SessionToggle.privacyMode, 'Privacy mode'),
    (SessionToggle.lockAfterSessionEnd, 'Lock when the session ends'),
    (SessionToggle.showRemoteCursor, 'Show the remote cursor'),
  ];

  @override
  Widget build(BuildContext context) => AnchoredMenu(
        width: 232,
        actions: [
          for (final entry in _toggles)
            MenuAction(
              label: entry.$2,
              isSelected: model.options.isEnabled(entry.$1),
              onTap: () => model.options.toggle(entry.$1),
            ),
          MenuAction(
            icon: model.options.isRecording
                ? LucideIcons.circleStop
                : LucideIcons.circleDot,
            label: model.options.isRecording
                ? 'Stop recording'
                : 'Start recording',
            onTap: () => model.options.setRecording(!model.options.isRecording),
          ),
          for (final preset in kImageQualityPresets)
            MenuAction(
              label: preset.$2,
              onTap: () => model.options.setImageQuality(preset.$1),
            ),
        ],
        builder: (context, open) => MenuTrigger(
          open: open,
          child: const Padding(
            padding: EdgeInsets.all(7),
            child:
                Icon(LucideIcons.settings2, size: 15, color: Color(0xFFF5DDD2)),
          ),
        ),
      );
}

/// The chat toggle, badged with unread messages.
class _ChatButton extends StatelessWidget {
  const _ChatButton(
      {required this.unread, required this.active, required this.onTap});

  final int unread;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        children: [
          _ToolbarButton(
              icon: LucideIcons.messageSquare, active: active, onTap: onTap),
          if (unread > 0)
            Positioned(
              top: -3,
              right: -3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFB55433),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(unread > 9 ? '9+' : '$unread',
                    style: const TextStyle(
                        color: CupertinoColors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      );
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton(
      {required this.icon, required this.onTap, this.active = false});
  final IconData icon;
  final VoidCallback onTap;

  /// Highlights a toggle that is currently on.
  final bool active;

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Container(
          width: 29,
          height: 29,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: active ? const Color(0xFF8C402A) : const Color(0xFF3B241C),
              borderRadius: BorderRadius.circular(7)),
          child: Icon(icon, size: 15, color: const Color(0xFFF5DDD2))));
}
