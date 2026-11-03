import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';

/// What a `rustdesk://` link or command line asked for.
enum ConnectionKind {
  remoteDesktop,
  fileTransfer,
  viewCamera,
  portForward,
  rdp,
  terminal,
}

extension ConnectionKindWindow on ConnectionKind {
  WindowType get windowType {
    switch (this) {
      case ConnectionKind.remoteDesktop:
        return WindowType.RemoteDesktop;
      case ConnectionKind.fileTransfer:
        return WindowType.FileTransfer;
      case ConnectionKind.viewCamera:
        return WindowType.ViewCamera;
      // RDP is a port-forward session with the RDP flag set.
      case ConnectionKind.portForward:
      case ConnectionKind.rdp:
        return WindowType.PortForward;
      case ConnectionKind.terminal:
        return WindowType.Terminal;
    }
  }

  /// The multi-window method that opens this session.
  String get newWindowEvent {
    switch (this) {
      case ConnectionKind.remoteDesktop:
        return kWindowEventNewRemoteDesktop;
      case ConnectionKind.fileTransfer:
        return kWindowEventNewFileTransfer;
      case ConnectionKind.viewCamera:
        return kWindowEventNewViewCamera;
      case ConnectionKind.portForward:
      case ConnectionKind.rdp:
        return kWindowEventNewPortForward;
      case ConnectionKind.terminal:
        return kWindowEventNewTerminal;
    }
  }
}

/// A parsed request to open a session.
@immutable
class ConnectionRequest {
  const ConnectionRequest({
    required this.kind,
    required this.peerId,
    this.password,
    this.switchUuid,
    this.forceRelay = false,
    this.isSharedPassword,
    this.connToken,
    this.isTerminalAdmin = false,
  });

  final ConnectionKind kind;
  final String peerId;
  final String? password;
  final String? switchUuid;
  final bool forceRelay;
  final bool? isSharedPassword;
  final String? connToken;

  /// `--terminal-admin` asked for an elevated terminal. The caller must set
  /// the `IS_TERMINAL_ADMIN` env var through the bridge before connecting.
  final bool isTerminalAdmin;

  bool get isRDP => kind == ConnectionKind.rdp;

  @override
  bool operator ==(Object other) =>
      other is ConnectionRequest &&
      other.kind == kind &&
      other.peerId == peerId &&
      other.password == password &&
      other.switchUuid == switchUuid &&
      other.forceRelay == forceRelay &&
      other.isSharedPassword == isSharedPassword &&
      other.connToken == connToken &&
      other.isTerminalAdmin == isTerminalAdmin;

  @override
  int get hashCode => Object.hash(kind, peerId, password, switchUuid,
      forceRelay, isSharedPassword, connToken, isTerminalAdmin);

  @override
  String toString() =>
      'ConnectionRequest($kind, $peerId, relay: $forceRelay)';
}

/// The outcome of parsing a link or argument list.
@immutable
class UriLinkResult {
  const UriLinkResult._({this.request, required this.showMainWindow});

  /// Open a session.
  const UriLinkResult.connect(ConnectionRequest request)
      : this._(request: request, showMainWindow: false);

  /// A bare `rustdesk://` link: just bring the main window forward.
  const UriLinkResult.showWindow() : this._(showMainWindow: true);

  /// Nothing to do — not a RustDesk link, or a form this layer does not own.
  const UriLinkResult.none() : this._(showMainWindow: false);

  final ConnectionRequest? request;
  final bool showMainWindow;

  bool get isHandled => request != null || showMainWindow;
}

/// Link authorities that carry a connection command.
const List<String> _kConnectAuthorities = [
  'connect',
  'play',
  'file-transfer',
  'view-camera',
  'port-forward',
  'rdp',
  'terminal',
  'terminal-admin',
];

/// Convert a `rustdesk://` URI to the command line form the core uses.
///
/// Ported from `urlLinkToCmdArgs` in `flutter_legacy/lib/common.dart`.
///
/// Returns null when the link is not a connection request. The `config` and
/// `password` deep links are mobile provisioning flows gated on buildin
/// options; they are intentionally not handled here and arrive with
/// Milestone 5. [isDeepLinkConfigOrPassword] identifies them so the caller can
/// route them rather than silently dropping them.
List<String>? uriToCmdArgs(Uri uri) {
  // rustdesk:// with nothing after it means "show the window".
  if (uri.authority.isEmpty &&
      uri.path.split('').every((char) => char == '/')) {
    return const [];
  }

  String? command;
  String? id;

  if (uri.authority == 'connection' && uri.path.startsWith('/new/')) {
    // Kept for compatibility with older links.
    command = '--connect';
    id = uri.path.substring('/new/'.length);
  } else if (uri.authority == 'config' || uri.authority == 'password') {
    // Mobile provisioning links; not a connection request.
    return null;
  } else if (_kConnectAuthorities.contains(uri.authority)) {
    command = '--${uri.authority}';
    if (uri.path.length > 1) id = uri.path.substring(1);
  } else if (uri.authority.length > 2 &&
      (uri.path.length <= 1 ||
          uri.path == '/r' ||
          uri.path.startsWith('/r@'))) {
    // rustdesk://<id>, rustdesk://<id>/r, rustdesk://<id>/r@<server>
    command = '--connect';
    id = uri.authority;
    if (uri.path.length > 1) id = id + uri.path;
  }

  if (command == null || id == null) return null;

  final query = uri.queryParameters
      .map((k, v) => MapEntry(k.toLowerCase(), v));

  final key = query['key'];
  if (key != null) id = '$id?key=$key';

  final args = <String>[command, id];
  final password = query['password'];
  if (password != null) args.addAll(['--password', password]);
  if (query['relay'] != null) args.add('--relay');
  return args;
}

/// True when [uri] is a mobile provisioning deep link rather than a
/// connection request.
bool isDeepLinkConfigOrPassword(Uri uri) =>
    uri.authority == 'config' || uri.authority == 'password';

/// Parse command line arguments into a connection request.
///
/// Ported from `handleUriLink` in `flutter_legacy/lib/common.dart`. Recognizes
/// the same flags in the same order, and tolerates a trailing flag whose value
/// is missing rather than throwing.
UriLinkResult parseCmdArgs(List<String> args) {
  if (args.isEmpty) return const UriLinkResult.showWindow();

  ConnectionKind? kind;
  String? id;
  String? password;
  String? switchUuid;
  var forceRelay = false;
  var terminalAdmin = false;

  String? valueAt(int i) => i + 1 < args.length ? args[i + 1] : null;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--connect':
      case '--play':
        kind = ConnectionKind.remoteDesktop;
        id = valueAt(i);
        i++;
        break;
      case '--file-transfer':
        kind = ConnectionKind.fileTransfer;
        id = valueAt(i);
        i++;
        break;
      case '--view-camera':
        kind = ConnectionKind.viewCamera;
        id = valueAt(i);
        i++;
        break;
      case '--port-forward':
        kind = ConnectionKind.portForward;
        id = valueAt(i);
        i++;
        break;
      case '--rdp':
        kind = ConnectionKind.rdp;
        id = valueAt(i);
        i++;
        break;
      case '--terminal':
        kind = ConnectionKind.terminal;
        id = valueAt(i);
        i++;
        break;
      case '--terminal-admin':
        terminalAdmin = true;
        kind = ConnectionKind.terminal;
        id = valueAt(i);
        i++;
        break;
      case '--password':
        password = valueAt(i);
        i++;
        break;
      case '--switch_uuid':
        switchUuid = valueAt(i);
        i++;
        break;
      case '--relay':
        forceRelay = true;
        break;
      default:
        break;
    }
  }

  if (kind == null || id == null || id.isEmpty) {
    return const UriLinkResult.none();
  }
  return UriLinkResult.connect(ConnectionRequest(
    kind: kind,
    peerId: id,
    password: password,
    switchUuid: switchUuid,
    forceRelay: forceRelay,
    isTerminalAdmin: terminalAdmin,
  ));
}

/// Parse a `rustdesk://` link into a connection request.
UriLinkResult parseUriLink(Uri uri) {
  final args = uriToCmdArgs(uri);
  if (args == null) return const UriLinkResult.none();
  return parseCmdArgs(args);
}
