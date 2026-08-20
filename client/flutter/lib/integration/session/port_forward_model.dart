import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// One tunnel from a local port to a host and port on the peer's network.
@immutable
class PortForward {
  const PortForward({
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  });

  /// Parse the peer config's `port_forwards` entry, which is a positional
  /// array: [localPort, remoteHost, remotePort].
  static PortForward? fromJson(dynamic raw) {
    if (raw is! List || raw.length < 3) return null;
    final local = int.tryParse('${raw[0]}');
    final remote = int.tryParse('${raw[2]}');
    if (local == null || remote == null) return null;
    return PortForward(
      localPort: local,
      remoteHost: raw[1]?.toString() ?? '',
      remotePort: remote,
    );
  }

  final int localPort;
  final String remoteHost;
  final int remotePort;

  @override
  bool operator ==(Object other) =>
      other is PortForward &&
      other.localPort == localPort &&
      other.remoteHost == remoteHost &&
      other.remotePort == remotePort;

  @override
  int get hashCode => Object.hash(localPort, remoteHost, remotePort);

  @override
  String toString() => 'localhost:$localPort → $remoteHost:$remotePort';
}

/// Port forwarding rules for one session.
///
/// Ported from `flutter_legacy/lib/desktop/pages/port_forward_page.dart`. The
/// rules live in the peer's config rather than session state, so they are read
/// back with `mainGetPeerSync` after every change.
class PortForwardModel extends ChangeNotifier {
  PortForwardModel({
    required this.sessionId,
    required this.peerId,
    RustdeskImpl? bindOverride,
  }) : _bindOverride = bindOverride;

  final UuidValue sessionId;
  final String peerId;
  final RustdeskImpl? _bindOverride;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  List<PortForward> _forwards = const [];
  Object? _error;

  List<PortForward> get forwards => List.unmodifiable(_forwards);

  Object? get error => _error;

  bool get isEmpty => _forwards.isEmpty;

  /// Re-read the rules from the peer config.
  Future<void> refresh() async {
    try {
      final raw = _bind.mainGetPeerSync(id: peerId);
      _forwards = parseForwards(raw);
      _error = null;
    } catch (e) {
      debugPrint('failed to read port forwards: $e');
      _error = e;
    }
    notifyListeners();
  }

  /// Add a tunnel. A local port already in use is rejected by the core.
  Future<void> add({
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    await _bind.sessionAddPortForward(
      sessionId: sessionId,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
    );
    await refresh();
  }

  Future<void> remove(int localPort) async {
    await _bind.sessionRemovePortForward(
        sessionId: sessionId, localPort: localPort);
    await refresh();
  }

  /// Open an RDP session through the tunnel.
  Future<void> openRdp() => _bind.sessionNewRdp(sessionId: sessionId);
}

/// Extract the port forward rules from a serialized peer config.
///
/// Returns an empty list rather than throwing: a peer with no rules, or a
/// config that cannot be parsed, both mean "nothing to show".
List<PortForward> parseForwards(String peerConfig) {
  if (peerConfig.isEmpty) return const [];
  try {
    final decoded = jsonDecode(peerConfig);
    if (decoded is! Map<String, dynamic>) return const [];
    final raw = decoded['port_forwards'];
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (PortForward.fromJson(entry) case final forward?) forward
    ];
  } catch (e) {
    debugPrint('failed to parse the peer config: $e');
    return const [];
  }
}
