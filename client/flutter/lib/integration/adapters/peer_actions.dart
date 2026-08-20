import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// Mutations on the local peer lists.
///
/// Ported from the menu actions in
/// `flutter_legacy/lib/common/widgets/peer_card.dart`. Each method issues the
/// same bridge calls in the same order as the legacy menu, including the
/// reload that makes the change visible: the core only re-emits a peer list
/// when asked.
///
/// Address book and group peers are owned by the server-backed models and are
/// not mutated here.
class PeerActions {
  const PeerActions();

  static const PeerActions instance = PeerActions();

  /// Set or clear a peer's alias.
  ///
  /// An empty [alias] clears it, which makes the peer display its id again.
  Future<void> setAlias(String peerId, String alias) async {
    await bind.mainSetPeerAlias(id: peerId, alias: alias);
    // The alias lives in peer config, so every list showing this peer is
    // stale until reloaded.
    await bind.mainLoadRecentPeers();
    await bind.mainLoadFavPeers();
  }

  /// The ids of every favorite peer.
  Future<List<String>> favoriteIds() => bind.mainGetFav();

  /// Whether [peerId] is currently a favorite.
  Future<bool> isFavorite(String peerId) async {
    final favs = await bind.mainGetFav();
    return favs.contains(peerId);
  }

  /// Add [peerId] to favorites. No-op when it already is one.
  Future<void> addFavorite(String peerId) async {
    final favs = (await bind.mainGetFav()).toList();
    if (favs.contains(peerId)) return;
    favs.add(peerId);
    await bind.mainStoreFav(favs: favs);
    await bind.mainLoadFavPeers();
  }

  /// Remove [peerId] from favorites. No-op when it is not one.
  Future<void> removeFavorite(String peerId) async {
    final favs = (await bind.mainGetFav()).toList();
    if (!favs.remove(peerId)) return;
    await bind.mainStoreFav(favs: favs);
    await bind.mainLoadFavPeers();
  }

  /// Toggle favorite state, returning the new state.
  Future<bool> toggleFavorite(String peerId) async {
    final favs = (await bind.mainGetFav()).toList();
    final nowFavorite = !favs.remove(peerId);
    if (nowFavorite) favs.add(peerId);
    await bind.mainStoreFav(favs: favs);
    await bind.mainLoadFavPeers();
    return nowFavorite;
  }

  /// Remove a peer from the list it appears in.
  ///
  /// Each source has its own removal call; using the wrong one silently does
  /// nothing. Address book and group peers are rejected rather than being
  /// removed from the wrong place.
  Future<bool> remove(String peerId, PeerSource source) async {
    switch (source) {
      case PeerSource.recent:
        await bind.mainRemovePeer(id: peerId);
        await bind.mainLoadRecentPeers();
        return true;
      case PeerSource.favorite:
        await removeFavorite(peerId);
        return true;
      case PeerSource.lan:
        await bind.mainRemoveDiscovered(id: peerId);
        await bind.mainLoadLanPeers();
        return true;
      case PeerSource.addressBook:
      case PeerSource.group:
        // Owned by the server-backed models; not a local mutation.
        debugPrint('refusing to locally remove a $source peer');
        return false;
    }
  }

  /// Forget the saved password for a peer.
  Future<void> forgetPassword(String peerId) =>
      bind.mainForgetPassword(id: peerId);

  /// Whether the core still knows this peer.
  Future<bool> exists(String peerId) => bind.mainPeerExists(id: peerId);
}

/// The process-wide peer actions.
PeerActions get peerActions => PeerActions.instance;
