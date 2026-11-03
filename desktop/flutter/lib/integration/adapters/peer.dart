import 'package:flutter/foundation.dart';

/// A remote peer.
///
/// Ported from `flutter_legacy/lib/models/peer_model.dart`. The JSON keys are
/// the serialized peer format shared with the Rust core, the address book, and
/// the on-disk cache; they must not be renamed. `device_group_name` keeps its
/// non-Dart casing for the same reason.
class Peer {
  Peer({
    required this.id,
    required this.hash,
    required this.password,
    required this.username,
    required this.hostname,
    required this.platform,
    required this.alias,
    required this.tags,
    required this.forceAlwaysRelay,
    required this.rdpPort,
    required this.rdpUsername,
    required this.loginName,
    required this.deviceGroupName,
    required this.note,
    this.sameServer,
  });

  Peer.fromJson(Map<String, dynamic> json)
      : id = json['id'] ?? '',
        hash = json['hash'] ?? '',
        password = json['password'] ?? '',
        username = json['username'] ?? '',
        hostname = json['hostname'] ?? '',
        platform = json['platform'] ?? '',
        alias = json['alias'] ?? '',
        tags = json['tags'] ?? [],
        forceAlwaysRelay = json['forceAlwaysRelay'] == 'true',
        rdpPort = json['rdpPort'] ?? '',
        rdpUsername = json['rdpUsername'] ?? '',
        loginName = json['loginName'] ?? '',
        deviceGroupName = json['device_group_name'] ?? '',
        note = json['note'] is String ? json['note'] : '',
        sameServer = json['same_server'];

  /// A placeholder row for an index that has not loaded yet.
  Peer.loading()
      : this(
          id: '...',
          hash: '',
          password: '',
          username: '...',
          hostname: '...',
          platform: '...',
          alias: '',
          tags: [],
          forceAlwaysRelay: false,
          rdpPort: '',
          rdpUsername: '',
          loginName: '',
          deviceGroupName: '',
          note: '',
        );

  factory Peer.copy(Peer other) {
    final peer = Peer(
      id: other.id,
      hash: other.hash,
      password: other.password,
      username: other.username,
      hostname: other.hostname,
      platform: other.platform,
      alias: other.alias,
      tags: other.tags.toList(),
      forceAlwaysRelay: other.forceAlwaysRelay,
      rdpPort: other.rdpPort,
      rdpUsername: other.rdpUsername,
      loginName: other.loginName,
      deviceGroupName: other.deviceGroupName,
      note: other.note,
      sameServer: other.sameServer,
    );
    peer.online = other.online;
    return peer;
  }

  final String id;

  /// Personal address book hash password.
  String hash;

  /// Shared address book password.
  String password;

  /// The remote machine's account name.
  String username;
  String hostname;
  String platform;
  String alias;
  List<dynamic> tags;
  bool forceAlwaysRelay;
  String rdpPort;
  String rdpUsername;

  /// The RustDesk account name that owns this entry.
  String loginName;

  /// Serialized as `device_group_name`.
  String deviceGroupName;
  String note;
  bool? sameServer;

  bool online = false;

  /// The label to show for this peer: its alias when set, otherwise its id.
  String get displayId => alias.isNotEmpty ? alias : id;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'hash': hash,
        'password': password,
        'username': username,
        'hostname': hostname,
        'platform': platform,
        'alias': alias,
        'tags': tags,
        'forceAlwaysRelay': forceAlwaysRelay.toString(),
        'rdpPort': rdpPort,
        'rdpUsername': rdpUsername,
        'loginName': loginName,
        'device_group_name': deviceGroupName,
        'note': note,
        'same_server': sameServer,
      };

  Map<String, dynamic> toCustomJson({required bool includingHash}) {
    final res = <String, dynamic>{
      'id': id,
      'username': username,
      'hostname': hostname,
      'platform': platform,
      'alias': alias,
      'tags': tags,
    };
    if (includingHash) res['hash'] = hash;
    return res;
  }

  Map<String, dynamic> toGroupCacheJson() => <String, dynamic>{
        'id': id,
        'username': username,
        'hostname': hostname,
        'platform': platform,
        'login_name': loginName,
        'device_group_name': deviceGroupName,
      };

  /// Value equality over the persisted fields. `online` is excluded because it
  /// is transient presence state, matching the legacy comparison.
  bool equal(Peer other) =>
      id == other.id &&
      hash == other.hash &&
      password == other.password &&
      username == other.username &&
      hostname == other.hostname &&
      platform == other.platform &&
      alias == other.alias &&
      listEquals(tags, other.tags) &&
      forceAlwaysRelay == other.forceAlwaysRelay &&
      rdpPort == other.rdpPort &&
      rdpUsername == other.rdpUsername &&
      deviceGroupName == other.deviceGroupName &&
      loginName == other.loginName &&
      note == other.note;

  @override
  String toString() => 'Peer($id, alias: $alias, online: $online)';
}

/// Peer platform strings reported by the core.
class PeerPlatform {
  static const String windows = 'Windows';
  static const String linux = 'Linux';
  static const String macOS = 'Mac OS';
  static const String android = 'Android';
  static const String webDesktop = 'WebDesktop';
}

/// The global event names the core emits when a peer list changes.
class PeerLoadEvent {
  static const String recent = 'load_recent_peers';
  static const String favorite = 'load_fav_peers';
  static const String lan = 'load_lan_peers';
  static const String addressBook = 'load_address_book_peers';
  static const String group = 'load_group_peers';
}

/// Sort keys persisted under `peer-sorting`.
class PeerSortType {
  static const String remoteId = 'Remote ID';
  static const String remoteHost = 'Remote Host';
  static const String username = 'Username';
  static const String status = 'Status';

  static const List<String> values = [remoteId, remoteHost, username, status];
}

/// Which peer list a view is showing.
enum PeerSource { recent, favorite, lan, addressBook, group }

extension PeerSourceEvent on PeerSource {
  /// The core event that signals this list changed.
  String get loadEvent {
    switch (this) {
      case PeerSource.recent:
        return PeerLoadEvent.recent;
      case PeerSource.favorite:
        return PeerLoadEvent.favorite;
      case PeerSource.lan:
        return PeerLoadEvent.lan;
      case PeerSource.addressBook:
        return PeerLoadEvent.addressBook;
      case PeerSource.group:
        return PeerLoadEvent.group;
    }
  }

  /// The handler name the legacy models registered under. Kept identical so
  /// both UIs can coexist during migration without clobbering each other.
  String get handlerName {
    switch (this) {
      case PeerSource.recent:
        return 'recent peer';
      case PeerSource.favorite:
        return 'fav peer';
      case PeerSource.lan:
        return 'discovered peer';
      case PeerSource.addressBook:
        return 'address book peer';
      case PeerSource.group:
        return 'group peer';
    }
  }
}

@immutable
class PeerSortOrder {
  const PeerSortOrder(this.type);

  final String type;

  /// Sort [peers] in place using the legacy comparison order: offline peers
  /// last, then the selected key, with id as the tiebreaker.
  void apply(List<Peer> peers) {
    peers.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      final int keyed;
      switch (type) {
        case PeerSortType.remoteHost:
          keyed = a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
          break;
        case PeerSortType.username:
          keyed = a.username.toLowerCase().compareTo(b.username.toLowerCase());
          break;
        case PeerSortType.status:
          keyed = 0;
          break;
        case PeerSortType.remoteId:
        default:
          keyed = a.displayId.toLowerCase().compareTo(b.displayId.toLowerCase());
      }
      if (keyed != 0) return keyed;
      return a.id.compareTo(b.id);
    });
  }
}
