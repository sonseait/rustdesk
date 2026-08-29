import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/adapters/account_adapter.dart';
import 'package:flutter_hbb/integration/adapters/address_book_adapter.dart';
import 'package:flutter_hbb/integration/adapters/connect_adapter.dart';
import 'package:flutter_hbb/integration/adapters/managed_client_adapter.dart';
import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/adapters/peer_actions.dart';
import 'package:flutter_hbb/integration/adapters/peers_adapter.dart';
import 'package:flutter_hbb/integration/adapters/service_status_adapter.dart';
import 'package:flutter_hbb/integration/bridge/app_bootstrap.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';

/// Which peer list the device view is showing.
enum PeerScope { recent, favorite, discovered, addressBook, group }

extension PeerScopeSource on PeerScope {
  /// The adapter source backing this scope, or null for scopes served by the
  /// address book and group caches rather than a peer list.
  PeerSource? get source {
    switch (this) {
      case PeerScope.recent:
        return PeerSource.recent;
      case PeerScope.favorite:
        return PeerSource.favorite;
      case PeerScope.discovered:
        return PeerSource.lan;
      case PeerScope.addressBook:
      case PeerScope.group:
        return null;
    }
  }

  String get label {
    switch (this) {
      case PeerScope.recent:
        return 'Recent';
      case PeerScope.favorite:
        return 'Favorites';
      case PeerScope.discovered:
        return 'Discovered';
      case PeerScope.addressBook:
        return 'Address book';
      case PeerScope.group:
        return 'Group';
    }
  }
}

/// How a list of peers is currently doing.
enum LoadState { loading, ready, empty, error }

/// The identity panel's view state.
@immutable
class IdentityView {
  const IdentityView({
    required this.deviceId,
    required this.isLoading,
    required this.isOnline,
    required this.isServiceRunning,
    required this.temporaryPassword,
    this.error,
  });

  /// Empty while the core is still generating it.
  final String deviceId;

  final bool isLoading;

  /// Registered with the rendezvous server.
  final bool isOnline;

  /// The local sharing service is accepting connections.
  final bool isServiceRunning;

  final String temporaryPassword;
  final Object? error;

  bool get hasError => error != null;

  /// The id formatted in groups of three, as RustDesk displays it.
  String get formattedDeviceId => formatPeerId(deviceId);
}

/// Format a numeric RustDesk id in groups of three.
///
/// Non-numeric ids (alias-style or already formatted) are returned unchanged.
String formatPeerId(String id) {
  final digits = id.replaceAll(' ', '');
  if (digits.isEmpty || int.tryParse(digits) == null) return id;
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Backs the workspace surfaces with real model data.
///
/// Owns the adapters the workspace needs, mirrors their state into one
/// listenable, and exposes the peer actions the UI offers. Every list carries
/// an explicit [LoadState] so a surface can tell "still loading" from
/// "genuinely empty" from "failed".
class WorkspaceViewModel extends ChangeNotifier {
  WorkspaceViewModel({
    ServiceStatusAdapter? serviceStatus,
    AccountAdapter? account,
    AddressBookAdapter? addressBook,
    GroupAdapter? groups,
    ConnectAdapter? connectAdapter,
    PeerActions? actions,
    OptionRepository? optionRepository,
    Map<PeerSource, PeerListAdapter>? peerLists,
  })  : _service = serviceStatus ?? ServiceStatusAdapter.instance,
        _account = account ?? AccountAdapter.instance,
        _addressBook = addressBook ?? AddressBookAdapter.instance,
        _groups = groups ?? GroupAdapter.instance,
        _connect = connectAdapter ?? ConnectAdapter.instance,
        _actions = actions ?? PeerActions.instance,
        _options = optionRepository ?? OptionRepository.instance,
        _peerLists = peerLists ??
            {
              for (final source in [
                PeerSource.recent,
                PeerSource.favorite,
                PeerSource.lan,
              ])
                source: PeerListAdapter(source),
            };

  final ServiceStatusAdapter _service;
  final AccountAdapter _account;
  final AddressBookAdapter _addressBook;
  final GroupAdapter _groups;
  final ConnectAdapter _connect;
  final PeerActions _actions;
  final OptionRepository _options;
  final Map<PeerSource, PeerListAdapter> _peerLists;

  bool _started = false;
  bool _disposed = false;

  PeerScope _scope = PeerScope.recent;
  String _query = '';
  bool _onlyOnline = false;
  String _sortType = PeerSortType.remoteId;
  Set<String> _favoriteIds = const {};

  // ------------------------------------------------------------------ status

  /// The identity panel's state, derived from the service status.
  IdentityView get identity {
    final s = _service.status;
    return IdentityView(
      deviceId: s.deviceId,
      isLoading: !s.isLoaded,
      isOnline: s.connectStatus == ConnectStatus.connected,
      isServiceRunning: s.isServiceRunning,
      temporaryPassword: s.temporaryPassword,
      error: s.error,
    );
  }

  ConnectStatus get connectStatus => _service.status.connectStatus;

  bool get isServiceRunning => _service.status.isServiceRunning;

  /// Whether the deployment forces every connection through a relay.
  bool get isForceRelay => _options.getBool(kOptionForceAlwaysRelay);

  /// The signed-in account name, or empty when signed out.
  String get accountName => _account.displayName;

  bool get isSignedIn => _account.isSignedIn;

  /// The bridge failure, when the app started without a working core.
  Object? get bridgeError => AppBootstrap.instance.error;

  /// Whether the native core is usable. Overridden by [FakeWorkspaceViewModel]
  /// so widget tests can exercise the surfaces without a native library.
  bool get isBridgeReady => AppBootstrap.instance.isReady;

  // ------------------------------------------------------------------- peers

  PeerScope get scope => _scope;

  String get query => _query;

  bool get onlyOnline => _onlyOnline;

  String get sortType => _sortType;

  /// Scopes that currently have anything to show, for the scope picker.
  List<PeerScope> get availableScopes {
    final scopes = <PeerScope>[
      PeerScope.recent,
      PeerScope.favorite,
      PeerScope.discovered,
    ];
    if (_addressBook.books.isNotEmpty) scopes.add(PeerScope.addressBook);
    if (_groups.peers.isNotEmpty) scopes.add(PeerScope.group);
    return scopes;
  }

  /// The peers for [scope], before search and filtering.
  List<Peer> peersOf(PeerScope scope) {
    switch (scope) {
      case PeerScope.addressBook:
        return _addressBook.currentPeers;
      case PeerScope.group:
        return _groups.peers;
      case PeerScope.recent:
      case PeerScope.favorite:
      case PeerScope.discovered:
        return _peerLists[scope.source!]?.peers ?? const [];
    }
  }

  /// The peers to render: current scope, searched, filtered and sorted.
  List<Peer> get visiblePeers {
    var peers = filterPeers(peersOf(scope), query);
    if (onlyOnline) {
      peers = peers.where((p) => p.online).toList();
    }
    PeerSortOrder(sortType).apply(peers);
    return peers;
  }

  /// How the current scope's list is doing.
  LoadState get loadState => loadStateOf(scope);

  LoadState loadStateOf(PeerScope scope) {
    final Object? error;
    final bool loaded;
    switch (scope) {
      case PeerScope.addressBook:
        error = _addressBook.error;
        loaded = _addressBook.isLoaded;
        break;
      case PeerScope.group:
        error = _groups.error;
        loaded = _groups.isLoaded;
        break;
      case PeerScope.recent:
      case PeerScope.favorite:
      case PeerScope.discovered:
        error = null;
        loaded = _peerLists[scope.source!]?.isLoaded ?? false;
        break;
    }
    if (error != null) return LoadState.error;
    if (!loaded) return LoadState.loading;
    return peersOf(scope).isEmpty ? LoadState.empty : LoadState.ready;
  }

  /// The error for the current scope, if it failed.
  Object? get scopeError {
    switch (scope) {
      case PeerScope.addressBook:
        return _addressBook.error;
      case PeerScope.group:
        return _groups.error;
      case PeerScope.recent:
      case PeerScope.favorite:
      case PeerScope.discovered:
        return null;
    }
  }

  /// Peers across every local list, for the command palette.
  List<Peer> get allKnownPeers {
    final seen = <String, Peer>{};
    for (final scope in PeerScope.values) {
      for (final peer in peersOf(scope)) {
        seen.putIfAbsent(peer.id, () => peer);
      }
    }
    final peers = seen.values.toList();
    PeerSortOrder(sortType).apply(peers);
    return peers;
  }

  int get onlineCount => allKnownPeers.where((p) => p.online).length;

  int get knownPeerCount => allKnownPeers.length;

  bool isFavorite(String peerId) => _favoriteIds.contains(peerId);

  // ---------------------------------------------------------------- mutation

  void setScope(PeerScope scope) {
    if (_scope == scope) return;
    _scope = scope;
    notifyListeners();
    // Discovery is broadcast-driven, so ask again each time it is shown.
    if (scope == PeerScope.discovered) unawaited(refreshScope(scope));
  }

  void setQuery(String query) {
    if (_query == query) return;
    _query = query;
    notifyListeners();
  }

  void setOnlyOnline(bool value) {
    if (_onlyOnline == value) return;
    _onlyOnline = value;
    notifyListeners();
  }

  Future<void> setSortType(String type) async {
    if (_sortType == type) return;
    _sortType = type;
    // Sorting is a persisted preference in the existing UI.
    await _options.setLocalString(kOptionPeerSorting, type);
    notifyListeners();
  }

  void selectAddressBook(String name) {
    _addressBook.select(name);
    notifyListeners();
  }

  // ------------------------------------------------------------------ actions

  /// Open a session with [peerId].
  Future<ConnectResult> connect(
    String peerId, {
    ConnectionKind kind = ConnectionKind.remoteDesktop,
    String? password,
    bool? isSharedPassword,
    String? switchUuid,
    bool forceRelay = false,
    String? connToken,
  }) async {
    final normalizedId = ConnectAdapter.normalizeId(peerId);
    final managed = ManagedClientAdapter.instance;
    try {
      await managed.refresh();
      if (managed.status.managedOnly && !managed.status.enrolled) {
        return ConnectResult.failure(normalizedId, ConnectFailure.failed,
            error: StateError('Managed configuration is unavailable.'));
      }
      if (managed.status.enrolled) {
        await managed.requestSessionTicketForRustdeskId(normalizedId);
      }
    } catch (error) {
      return ConnectResult.failure(normalizedId, ConnectFailure.failed,
          error: error);
    }
    return _connect.connect(
      peerId,
      kind: kind,
      password: password,
      isSharedPassword: isSharedPassword,
      switchUuid: switchUuid,
      connToken: connToken,
      // Peers carry their own relay preference; the global option is honored
      // by the core, so only the per-peer flag is passed here.
      forceRelay: forceRelay || _peerForceRelay(peerId),
    );
  }

  bool _peerForceRelay(String peerId) {
    for (final peer in allKnownPeers) {
      if (peer.id == ConnectAdapter.normalizeId(peerId)) {
        return peer.forceAlwaysRelay;
      }
    }
    return false;
  }

  Future<void> setAlias(String peerId, String alias) async {
    await _actions.setAlias(peerId, alias);
    await refreshAll();
  }

  Future<void> toggleFavorite(String peerId) async {
    await _actions.toggleFavorite(peerId);
    await _refreshFavorites();
    notifyListeners();
  }

  /// Remove a peer from the list it is shown in. Returns false when the
  /// current scope does not own its peers.
  Future<bool> removePeer(String peerId) async {
    final source = scope.source;
    if (source == null) return false;
    final removed = await _actions.remove(peerId, source);
    if (removed) await _refreshFavorites();
    return removed;
  }

  Future<void> forgetPassword(String peerId) => _actions.forgetPassword(peerId);

  // ----------------------------------------------------------------- loading

  /// Start listening and load everything. Safe to call once.
  ///
  /// When the native bridge failed to initialize there is nothing to read, so
  /// this returns early and the surfaces render [bridgeError] instead of an
  /// empty-but-healthy workspace.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    if (!isBridgeReady) {
      debugPrint('workspace started without a usable bridge');
      _onChanged();
      return;
    }

    _service.addListener(_onChanged);
    _account.addListener(_onChanged);
    _addressBook.addListener(_onChanged);
    _groups.addListener(_onChanged);
    for (final list in _peerLists.values) {
      list.addListener(_onChanged);
    }

    _sortType = _readSortType();
    _service.start();

    await Future.wait([
      _account.load(),
      _addressBook.load(),
      _groups.load(),
      refreshAll(),
      _refreshFavorites(),
    ]);
    _onChanged();
  }

  String _readSortType() {
    final stored = _options.getLocalString(kOptionPeerSorting);
    return PeerSortType.values.contains(stored)
        ? stored
        : PeerSortType.remoteId;
  }

  /// Ask the core to re-emit every local peer list.
  Future<void> refreshAll() async {
    await Future.wait(_peerLists.values.map((list) => list.refresh()));
  }

  Future<void> refreshScope(PeerScope scope) async {
    final source = scope.source;
    if (source != null) {
      await _peerLists[source]?.refresh();
      return;
    }
    if (scope == PeerScope.addressBook) await _addressBook.load();
    if (scope == PeerScope.group) await _groups.load();
  }

  Future<void> _refreshFavorites() async {
    try {
      _favoriteIds = (await _actions.favoriteIds()).toSet();
    } catch (e) {
      debugPrint('failed to read favorites: $e');
      _favoriteIds = const {};
    }
  }

  void _onChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_started || !isBridgeReady) {
      super.dispose();
      return;
    }
    _service.removeListener(_onChanged);
    _account.removeListener(_onChanged);
    _addressBook.removeListener(_onChanged);
    _groups.removeListener(_onChanged);
    for (final list in _peerLists.values) {
      list.removeListener(_onChanged);
      list.dispose();
    }
    super.dispose();
  }
}
