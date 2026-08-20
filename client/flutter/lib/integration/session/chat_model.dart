import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// Who sent a chat message.
enum ChatAuthor { me, peer }

@immutable
class ChatMessage {
  const ChatMessage({
    required this.author,
    required this.text,
    required this.at,
  });

  final ChatAuthor author;
  final String text;
  final DateTime at;
}

/// Text chat with the peer.
///
/// Ported from the session half of `ChatModel` in
/// `flutter_legacy/lib/models/chat_model.dart`. Incoming messages arrive on
/// the `chat_client_mode` event.
class ChatModel extends ChangeNotifier {
  ChatModel({
    required this.sessionId,
    RustdeskImpl? bindOverride,
    DateTime Function()? clock,
  })  : _bindOverride = bindOverride,
        _clock = clock ?? DateTime.now;

  final UuidValue sessionId;
  final RustdeskImpl? _bindOverride;

  /// Injectable so tests do not depend on the wall clock.
  final DateTime Function() _clock;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  final List<ChatMessage> _messages = [];
  int _unread = 0;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Messages received while the panel was closed.
  int get unreadCount => _unread;

  bool get isEmpty => _messages.isEmpty;

  /// Handle a session event. Returns true when it was a chat event.
  bool handleEvent(Map<String, dynamic> event) {
    // The client-mode event is the one a controlling session receives.
    if (event['name'] != 'chat_client_mode') return false;
    final text = event['text']?.toString() ?? '';
    if (text.isEmpty) return true;
    _messages.add(ChatMessage(
      author: ChatAuthor.peer,
      text: text,
      at: _clock(),
    ));
    _unread++;
    notifyListeners();
    return true;
  }

  /// Send a message to the peer.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _messages.add(ChatMessage(
      author: ChatAuthor.me,
      text: trimmed,
      at: _clock(),
    ));
    notifyListeners();
    await _bind.sessionSendChat(sessionId: sessionId, text: trimmed);
  }

  /// Mark everything read, e.g. when the panel opens.
  void markRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  void clear() {
    _messages.clear();
    _unread = 0;
    notifyListeners();
  }
}
