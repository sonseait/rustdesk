import 'package:flutter_hbb/features/workspace/workspace_view_model.dart';
import 'package:flutter_hbb/integration/adapters/connect_adapter.dart';
import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/adapters/service_status_adapter.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';

/// An in-memory [WorkspaceViewModel] for widget tests.
///
/// Widget tests run without the native library, so the real model reports the
/// bridge as unavailable. This subclass supplies model-shaped data instead,
/// and records the calls the UI makes so tests can assert the surfaces invoke
/// the same actions the adapters expose.
class FakeWorkspaceViewModel extends WorkspaceViewModel {
  FakeWorkspaceViewModel({
    List<Peer>? recent,
    List<Peer>? favorites,
    List<Peer>? discovered,
    this.identityOverride = const IdentityView(
      deviceId: '847293160',
      isLoading: false,
      isOnline: true,
      isServiceRunning: true,
      temporaryPassword: 'abc123',
    ),
    this.bridgeReady = true,
    this.stateOverride = LoadState.ready,
    this.connectResult,
  })  : _recent = recent ?? const [],
        _favorites = favorites ?? const [],
        _discovered = discovered ?? const [];

  final List<Peer> _recent;
  final List<Peer> _favorites;
  final List<Peer> _discovered;

  final IdentityView identityOverride;
  final bool bridgeReady;
  final LoadState stateOverride;
  final ConnectResult? connectResult;

  /// Calls the UI made, in order.
  final List<(String, ConnectionKind)> connectCalls = [];
  final List<String> favoriteToggles = [];
  final List<String> removals = [];
  final List<(String, String)> aliasChanges = [];
  final List<String> forgottenPasswords = [];

  final Set<String> _favoriteIds = {};

  @override
  bool get isBridgeReady => bridgeReady;

  @override
  Object? get bridgeError => bridgeReady ? null : 'no native library';

  @override
  IdentityView get identity => identityOverride;

  @override
  ConnectStatus get connectStatus => identityOverride.isOnline
      ? ConnectStatus.connected
      : ConnectStatus.disconnected;

  @override
  bool get isServiceRunning => identityOverride.isServiceRunning;

  @override
  bool get isForceRelay => false;

  @override
  String get accountName => '';

  @override
  bool get isSignedIn => false;

  @override
  Future<void> start() async {}

  @override
  List<Peer> peersOf(PeerScope scope) {
    switch (scope) {
      case PeerScope.recent:
        return _recent;
      case PeerScope.favorite:
        return _favorites;
      case PeerScope.discovered:
        return _discovered;
      case PeerScope.addressBook:
      case PeerScope.group:
        return const [];
    }
  }

  @override
  LoadState loadStateOf(PeerScope scope) {
    if (stateOverride != LoadState.ready) return stateOverride;
    return peersOf(scope).isEmpty ? LoadState.empty : LoadState.ready;
  }

  @override
  Object? get scopeError =>
      stateOverride == LoadState.error ? 'device list unavailable' : null;

  @override
  List<PeerScope> get availableScopes =>
      [PeerScope.recent, PeerScope.favorite, PeerScope.discovered];

  @override
  bool isFavorite(String peerId) => _favoriteIds.contains(peerId);

  void markFavorite(String peerId) => _favoriteIds.add(peerId);

  @override
  Future<ConnectResult> connect(
    String peerId, {
    ConnectionKind kind = ConnectionKind.remoteDesktop,
    String? password,
    bool? isSharedPassword,
    String? switchUuid,
    bool forceRelay = false,
    String? connToken,
  }) async {
    connectCalls.add((peerId, kind));
    // Desktop opens the session in its own window, so the workspace does not
    // push a session route. Tests that want the mobile push set windowId null
    // through connectResult.
    return connectResult ??
        ConnectResult.success(ConnectAdapter.normalizeId(peerId),
            windowId: 1);
  }

  @override
  Future<void> toggleFavorite(String peerId) async {
    favoriteToggles.add(peerId);
    if (!_favoriteIds.remove(peerId)) _favoriteIds.add(peerId);
    notifyListeners();
  }

  @override
  Future<bool> removePeer(String peerId) async {
    removals.add(peerId);
    return true;
  }

  @override
  Future<void> setAlias(String peerId, String alias) async {
    aliasChanges.add((peerId, alias));
  }

  @override
  Future<void> forgetPassword(String peerId) async {
    forgottenPasswords.add(peerId);
  }

  String _sortType = PeerSortType.remoteId;

  @override
  String get sortType => _sortType;

  /// Sorting is persisted through an option write in the real model, which
  /// needs a live bridge; here it is just recorded.
  @override
  Future<void> setSortType(String type) async {
    if (_sortType == type) return;
    _sortType = type;
    notifyListeners();
  }
}

/// Build a peer with test-friendly defaults.
Peer testPeer(
  String id, {
  String alias = '',
  String hostname = '',
  String username = '',
  String platform = PeerPlatform.macOS,
  bool online = false,
}) {
  final peer = Peer.fromJson({
    'id': id,
    'alias': alias,
    'hostname': hostname,
    'username': username,
    'platform': platform,
  });
  peer.online = online;
  return peer;
}
