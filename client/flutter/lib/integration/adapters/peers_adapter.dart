import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// Why a peer list changed.
enum PeerUpdateKind {
  /// The list contents were replaced.
  load,

  /// Only online/offline presence changed.
  presence,
}

/// Read-only view of one peer list.
///
/// Ported from the `Peers` model in `flutter_legacy/lib/models/peer_model.dart`.
/// The core pushes updates through the global event stream; [refresh] asks it
/// to emit one. Milestone 0 does not mutate peers.
class PeerListAdapter extends ChangeNotifier {
  PeerListAdapter(this.source) {
    _register();
  }

  static const String _onlinesEvent = 'callback_query_onlines';

  final PeerSource source;

  List<Peer> _peers = const [];
  List<String> _restPeerIds = const [];
  PeerUpdateKind _lastUpdate = PeerUpdateKind.load;
  bool _isLoaded = false;
  bool _disposed = false;

  List<Peer> get peers => List.unmodifiable(_peers);

  /// Ids of peers not yet materialized. The core sends the first page of a
  /// large list up front and the remaining ids separately.
  List<String> get restPeerIds => List.unmodifiable(_restPeerIds);

  PeerUpdateKind get lastUpdate => _lastUpdate;

  /// False until the core has delivered this list at least once, so the UI can
  /// tell "still loading" from "genuinely empty".
  bool get isLoaded => _isLoaded;

  bool get isEmpty => _isLoaded && _peers.isEmpty;

  int get count => _peers.length;

  Peer peerAt(int index) =>
      index < _peers.length ? _peers[index] : Peer.loading();

  void _register() {
    platformFFI.registerEventHandler(
      source.loadEvent,
      source.handlerName,
      (evt) async => _onPeersLoaded(evt),
      replace: true,
    );
    platformFFI.registerEventHandler(
      _onlinesEvent,
      source.handlerName,
      (evt) async => _onPresenceChanged(evt),
      replace: true,
    );
  }

  /// Ask the core to re-emit this list. The result arrives asynchronously on
  /// the event stream.
  Future<void> refresh() async {
    switch (source) {
      case PeerSource.recent:
        await bind.mainLoadRecentPeers();
        break;
      case PeerSource.favorite:
        await bind.mainLoadFavPeers();
        break;
      case PeerSource.lan:
        await bind.mainLoadLanPeers();
        // Discovery is a separate broadcast; the legacy view issues both.
        await bind.mainDiscover();
        break;
      case PeerSource.addressBook:
      case PeerSource.group:
        // These lists are owned by the address book and group adapters, which
        // push into the core; there is no direct reload call.
        break;
    }
  }

  void _onPeersLoaded(Map<String, dynamic> evt) {
    final presence = {for (final p in _peers) p.id: p.online};
    final next = _decodePeers(evt['peers'] as String? ?? '');

    final ids = evt['ids'] as String?;
    _restPeerIds = (ids == null || ids.isEmpty) ? const [] : ids.split(',');

    for (final peer in next) {
      peer.online = presence[peer.id] ?? false;
    }

    _peers = next;
    _isLoaded = true;
    _lastUpdate = PeerUpdateKind.load;
    _notify();
  }

  void _onPresenceChanged(Map<String, dynamic> evt) {
    var changed = 0;
    changed += _setPresence(evt['onlines'] as String?, online: true);
    changed += _setPresence(evt['offlines'] as String?, online: false);
    if (changed == 0) return;
    _lastUpdate = PeerUpdateKind.presence;
    _notify();
  }

  int _setPresence(String? csv, {required bool online}) {
    if (csv == null || csv.isEmpty) return 0;
    final ids = csv.split(',').toSet();
    var changed = 0;
    for (final peer in _peers) {
      if (ids.contains(peer.id) && peer.online != online) {
        peer.online = online;
        changed++;
      }
    }
    return changed;
  }

  List<Peer> _decodePeers(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = json.decode(raw) as List<dynamic>;
      return decoded
          .map((e) => Peer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('failed to decode ${source.loadEvent}: $e');
      return const [];
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    platformFFI.unregisterEventHandler(source.loadEvent, source.handlerName);
    platformFFI.unregisterEventHandler(_onlinesEvent, source.handlerName);
    super.dispose();
  }
}

/// Filter [peers] by a search string, matching the legacy fields: id, alias,
/// hostname and username, case-insensitively.
List<Peer> filterPeers(List<Peer> peers, String search) {
  final query = search.trim().toLowerCase();
  if (query.isEmpty) return List.of(peers);
  return peers.where((p) {
    return p.id.toLowerCase().contains(query) ||
        p.alias.toLowerCase().contains(query) ||
        p.hostname.toLowerCase().contains(query) ||
        p.username.toLowerCase().contains(query);
  }).toList();
}
