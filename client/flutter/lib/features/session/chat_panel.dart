import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/integration/session/chat_model.dart';

/// Text chat with the peer, shown beside the session.
class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key, required this.chat, required this.onClose});

  final ChatModel chat;
  final VoidCallback onClose;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChanged);
    // Opening the panel means the user has seen what arrived. Deferred to
    // after the frame: markRead notifies, and notifying during build throws.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.chat.markRead();
    });
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    // Both of these run after the frame: markRead notifies listeners, and the
    // scroll extent is only known once the new message has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.chat.markRead();
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChanged);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    widget.chat.send(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) => Container(
        width: 268,
        decoration: const BoxDecoration(
          color: Color(0xFF1B1211),
          border: Border(left: BorderSide(color: Color(0xFF4A3029))),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
            child: Row(children: [
              const Icon(LucideIcons.messageSquare,
                  size: 14, color: Color(0xFFF5B69B)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Chat',
                    style: TextStyle(
                        color: CupertinoColors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(LucideIcons.x,
                    size: 14, color: Color(0xFF9C8279)),
              ),
            ]),
          ),
          Expanded(child: _messages()),
          _composer(),
        ]),
      );

  Widget _messages() {
    if (widget.chat.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No messages yet',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF9C8279), fontSize: 11)),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      itemCount: widget.chat.messages.length,
      itemBuilder: (context, index) =>
          _Bubble(message: widget.chat.messages[index]),
    );
  }

  Widget _composer() => Padding(
        padding: const EdgeInsets.all(9),
        child: Row(children: [
          Expanded(
            child: CupertinoTextField(
              controller: _controller,
              onSubmitted: (_) => _send(),
              placeholder: 'Message',
              placeholderStyle:
                  const TextStyle(color: Color(0xFF6B564E), fontSize: 11),
              style: const TextStyle(
                  color: CupertinoColors.white, fontSize: 11),
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1C17),
                border: Border.all(color: const Color(0xFF4A3029)),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(width: 7),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF8C402A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(LucideIcons.send,
                  size: 13, color: Color(0xFFF5DDD2)),
            ),
          ),
        ]),
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isMine = message.author == ChatAuthor.me;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 200),
        decoration: BoxDecoration(
          color: isMine ? const Color(0xFF8C402A) : const Color(0xFF2A1C17),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(message.text,
            style: TextStyle(
                color: isMine
                    ? CupertinoColors.white
                    : const Color(0xFFE8D6CE),
                fontSize: 11)),
      ),
    );
  }
}
