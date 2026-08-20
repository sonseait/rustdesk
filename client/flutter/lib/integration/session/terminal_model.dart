import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// A terminal that erases only scrollback, keeping the visible screen.
///
/// Ported from `RustDeskTerminal` in
/// `flutter_legacy/lib/models/rustdesk_terminal.dart`.
class RustDeskTerminal extends Terminal {
  RustDeskTerminal({super.maxLines});

  @override
  void eraseScrollbackOnly() {
    final scrollBack = buffer.scrollBack;
    if (scrollBack == 0) return;
    // Selection anchors require retained buffer lines to be reindexed.
    buffer.lines.remove(0, scrollBack);
  }
}

/// One remote shell.
///
/// Ported from `TerminalModel` in
/// `flutter_legacy/lib/models/terminal_model.dart`. Output arrives on the
/// session's `terminal_response` event, base64 encoded.
///
/// Output that arrives before the view has laid out is buffered: writing to an
/// xterm with no dimensions produces NaN geometry.
class TerminalModel extends ChangeNotifier {
  TerminalModel({
    required this.sessionId,
    required this.terminalId,
    RustdeskImpl? bindOverride,
  }) : _bindOverride = bindOverride {
    terminal.onOutput = _onUserInput;
    terminal.onResize = _onResize;
  }

  final UuidValue sessionId;
  final int terminalId;
  final RustdeskImpl? _bindOverride;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  final terminal = RustDeskTerminal(maxLines: 10000);

  bool _opened = false;
  bool _closed = false;
  bool _viewReady = false;
  String? _error;

  /// Output received before the view could render it.
  final _pending = StringBuffer();

  /// Input typed before the shell was open.
  final _pendingInput = <String>[];

  /// Set when the peer replays buffered output on reconnect. xterm answers
  /// terminal queries in that replay through onOutput, and those answers must
  /// not be sent back to the peer.
  bool _suppressNextOutput = false;

  bool get isOpened => _opened;

  bool get isClosed => _closed;

  String? get error => _error;

  /// Ask the peer to start a shell.
  Future<void> open({int rows = 24, int cols = 80}) async {
    if (_opened || _closed) return;
    await _bind.sessionOpenTerminal(
      sessionId: sessionId,
      terminalId: terminalId,
      rows: rows,
      cols: cols,
    );
  }

  /// The view has laid out and can render buffered output.
  void markViewReady() {
    if (_viewReady) return;
    _viewReady = true;
    if (_pending.isNotEmpty) {
      terminal.write(_pending.toString());
      _pending.clear();
    }
    notifyListeners();
  }

  /// Handle a `terminal_response` event.
  ///
  /// Returns false when the event belongs to a different terminal, so a
  /// session with several tabs routes correctly.
  bool handleResponse(Map<String, dynamic> event) {
    if (terminalIdOf(event) != terminalId) return false;
    switch (event['type']) {
      case 'opened':
        _handleOpened(event);
        break;
      case 'data':
        _handleData(event);
        break;
      case 'closed':
        _handleClosed(event);
        break;
      case 'error':
        _handleError(event);
        break;
      default:
        return false;
    }
    return true;
  }

  void _handleOpened(Map<String, dynamic> event) {
    final success = event['success'] == true || event['success'] == 'true';
    if (!success) {
      _error = event['message']?.toString() ?? 'Failed to open the terminal';
      notifyListeners();
      return;
    }
    _opened = true;
    _error = null;

    // A reconnect replays recent output, which may contain terminal queries.
    final replayed = event['replay_terminal_output'] == true ||
        event['message'] ==
            'Reconnected to existing terminal with pending output';
    _suppressNextOutput = replayed;

    for (final input in _pendingInput) {
      unawaitedSend(input);
    }
    _pendingInput.clear();
    notifyListeners();
  }

  void _handleData(Map<String, dynamic> event) {
    final decoded = decodeTerminalData(event['data']);
    if (decoded == null) return;
    final suppress = _suppressNextOutput;
    _suppressNextOutput = false;
    _write(decoded, suppressEcho: suppress);
  }

  void _handleClosed(Map<String, dynamic> event) {
    _closed = true;
    _opened = false;
    notifyListeners();
  }

  void _handleError(Map<String, dynamic> event) {
    _error = event['message']?.toString() ?? 'Terminal error';
    notifyListeners();
  }

  void _write(String text, {bool suppressEcho = false}) {
    if (!_viewReady) {
      // Cap the buffer so a long pre-layout window cannot grow without bound.
      const cap = 256 * 1024;
      if (_pending.length + text.length > cap) {
        final kept = text.length >= cap ? text.substring(text.length - cap)
            : text;
        _pending.clear();
        _pending.write(kept);
      } else {
        _pending.write(text);
      }
      return;
    }
    if (suppressEcho) {
      // Detach the output handler while the replay is written, so xterm's
      // automatic replies do not travel back to the peer.
      terminal.onOutput = null;
      terminal.write(text);
      terminal.onOutput = _onUserInput;
      return;
    }
    terminal.write(text);
  }

  void _onUserInput(String data) {
    if (!_opened) {
      _pendingInput.add(data);
      return;
    }
    unawaitedSend(data);
  }

  void unawaitedSend(String data) {
    _bind
        .sessionSendTerminalInput(
            sessionId: sessionId, terminalId: terminalId, data: data)
        .catchError((Object e) {
      debugPrint('failed to send terminal input: $e');
    });
  }

  void _onResize(int width, int height, int pixelWidth, int pixelHeight) {
    if (!_opened) return;
    _bind
        .sessionResizeTerminal(
            sessionId: sessionId,
            terminalId: terminalId,
            rows: height,
            cols: width)
        .catchError((Object e) {
      debugPrint('failed to resize the terminal: $e');
    });
  }

  /// Close the shell on the peer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _bind.sessionCloseTerminal(
          sessionId: sessionId, terminalId: terminalId);
    } catch (e) {
      debugPrint('failed to close the terminal: $e');
    }
  }

  @override
  void dispose() {
    terminal.onOutput = null;
    terminal.onResize = null;
    super.dispose();
  }
}

/// The terminal id carried by an event.
///
/// Desktop sends an int, web sends a string; both have to work.
int terminalIdOf(Map<String, dynamic> event) {
  final raw = event['terminal_id'];
  if (raw is int) return raw;
  if (raw is String) return int.tryParse(raw) ?? -1;
  return -1;
}

/// Decode terminal output, which arrives base64 encoded.
///
/// Falls back to treating the payload as plain text, matching the legacy
/// behavior: some paths send raw strings.
String? decodeTerminalData(dynamic data) {
  if (data == null) return null;
  if (data is List) {
    return utf8.decode(List<int>.from(data), allowMalformed: true);
  }
  if (data is! String) {
    debugPrint('unexpected terminal data type: ${data.runtimeType}');
    return null;
  }
  try {
    return utf8.decode(base64Decode(data), allowMalformed: true);
  } catch (_) {
    return data;
  }
}

/// Owns the terminals for one session.
class TerminalRegistry extends ChangeNotifier {
  TerminalRegistry({required this.sessionId, RustdeskImpl? bindOverride})
      : _bindOverride = bindOverride;

  final UuidValue sessionId;
  final RustdeskImpl? _bindOverride;

  final Map<int, TerminalModel> _terminals = {};
  int _nextId = 1;

  List<TerminalModel> get terminals => _terminals.values.toList();

  bool get isEmpty => _terminals.isEmpty;

  /// Open a new shell.
  Future<TerminalModel> openTerminal({int rows = 24, int cols = 80}) async {
    final id = _nextId++;
    final model = TerminalModel(
      sessionId: sessionId,
      terminalId: id,
      bindOverride: _bindOverride,
    );
    _terminals[id] = model;
    model.addListener(notifyListeners);
    notifyListeners();
    await model.open(rows: rows, cols: cols);
    return model;
  }

  /// Route a `terminal_response` event to its terminal.
  bool handleEvent(Map<String, dynamic> event) {
    if (event['name'] != 'terminal_response') return false;
    for (final model in _terminals.values) {
      if (model.handleResponse(event)) return true;
    }
    return false;
  }

  Future<void> closeTerminal(int id) async {
    final model = _terminals.remove(id);
    if (model == null) return;
    model.removeListener(notifyListeners);
    await model.close();
    model.dispose();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final model in _terminals.values) {
      model.removeListener(notifyListeners);
      unawaited(model.close());
      model.dispose();
    }
    _terminals.clear();
    super.dispose();
  }
}
