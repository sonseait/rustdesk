import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/adapters/account_types.dart';
import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/adapters/peers_adapter.dart';
import 'package:flutter_hbb/integration/adapters/service_status_adapter.dart';

void main() {
  group('Peer serialization', () {
    // The peer JSON is shared with the Rust core, the address book API, and
    // the on-disk cache.
    const raw = {
      'id': '123456789',
      'hash': 'the-hash',
      'password': 'the-password',
      'username': 'ada',
      'hostname': 'workstation',
      'platform': 'Linux',
      'alias': 'Lab box',
      'tags': ['lab', 'linux'],
      'forceAlwaysRelay': 'true',
      'rdpPort': '3389',
      'rdpUsername': 'rdp-user',
      'loginName': 'ada@example.com',
      'device_group_name': 'Lab',
      'note': 'a note',
      'same_server': true,
    };

    test('round-trips every field', () {
      final peer = Peer.fromJson(Map<String, dynamic>.from(raw));

      expect(peer.id, '123456789');
      expect(peer.hash, 'the-hash');
      expect(peer.username, 'ada');
      expect(peer.hostname, 'workstation');
      expect(peer.alias, 'Lab box');
      expect(peer.tags, ['lab', 'linux']);
      // Serialized as the string 'true', not a bool.
      expect(peer.forceAlwaysRelay, isTrue);
      expect(peer.rdpPort, '3389');
      expect(peer.deviceGroupName, 'Lab');
      expect(peer.sameServer, isTrue);

      expect(peer.toJson(), raw);
    });

    test('tolerates a completely empty payload', () {
      final peer = Peer.fromJson(<String, dynamic>{});

      expect(peer.id, '');
      expect(peer.tags, isEmpty);
      expect(peer.forceAlwaysRelay, isFalse);
      expect(peer.sameServer, isNull);
    });

    test('a non-string note is dropped rather than crashing', () {
      final peer = Peer.fromJson({'id': 'x', 'note': 42});
      expect(peer.note, '');
    });

    test('displayId prefers the alias', () {
      final aliased = Peer.fromJson({'id': '1', 'alias': 'Lab'});
      final plain = Peer.fromJson({'id': '1'});

      expect(aliased.displayId, 'Lab');
      expect(plain.displayId, '1');
    });

    test('copy is deep for tags and carries presence', () {
      final original = Peer.fromJson(Map<String, dynamic>.from(raw));
      original.online = true;

      final copy = Peer.copy(original);
      copy.tags.add('extra');

      expect(copy.online, isTrue);
      expect(original.tags, ['lab', 'linux']);
      expect(original.equal(copy), isFalse);
    });

    test('equal ignores transient presence', () {
      final a = Peer.fromJson(Map<String, dynamic>.from(raw));
      final b = Peer.fromJson(Map<String, dynamic>.from(raw));
      b.online = true;

      expect(a.equal(b), isTrue);
    });

    test('the group cache payload keeps its snake_case keys', () {
      final peer = Peer.fromJson(Map<String, dynamic>.from(raw));

      expect(peer.toGroupCacheJson(), {
        'id': '123456789',
        'username': 'ada',
        'hostname': 'workstation',
        'platform': 'Linux',
        'login_name': 'ada@example.com',
        'device_group_name': 'Lab',
      });
    });

    test('the custom payload includes the hash only when asked', () {
      final peer = Peer.fromJson(Map<String, dynamic>.from(raw));

      expect(peer.toCustomJson(includingHash: true)['hash'], 'the-hash');
      expect(
          peer.toCustomJson(includingHash: false).containsKey('hash'), isFalse);
    });
  });

  group('PeerSource event contract', () {
    test('each source maps to its core event and handler name', () {
      expect(PeerSource.recent.loadEvent, 'load_recent_peers');
      expect(PeerSource.favorite.loadEvent, 'load_fav_peers');
      expect(PeerSource.lan.loadEvent, 'load_lan_peers');
      expect(PeerSource.addressBook.loadEvent, 'load_address_book_peers');
      expect(PeerSource.group.loadEvent, 'load_group_peers');

      expect(PeerSource.recent.handlerName, 'recent peer');
      expect(PeerSource.lan.handlerName, 'discovered peer');
    });
  });

  group('peer sorting', () {
    List<Peer> makePeers() => [
          Peer.fromJson({'id': '3', 'hostname': 'aaa', 'username': 'zoe'}),
          Peer.fromJson({'id': '1', 'hostname': 'ccc', 'username': 'ada'}),
          Peer.fromJson({'id': '2', 'hostname': 'bbb', 'username': 'moe'}),
        ];

    test('offline peers sort after online ones regardless of key', () {
      final peers = makePeers();
      peers[0].online = true;

      const PeerSortOrder(PeerSortType.remoteId).apply(peers);

      expect(peers.first.id, '3');
    });

    test('sorts by id, host and username', () {
      var peers = makePeers();
      const PeerSortOrder(PeerSortType.remoteId).apply(peers);
      expect(peers.map((p) => p.id).toList(), ['1', '2', '3']);

      peers = makePeers();
      const PeerSortOrder(PeerSortType.remoteHost).apply(peers);
      expect(peers.map((p) => p.hostname).toList(), ['aaa', 'bbb', 'ccc']);

      peers = makePeers();
      const PeerSortOrder(PeerSortType.username).apply(peers);
      expect(peers.map((p) => p.username).toList(), ['ada', 'moe', 'zoe']);
    });

    test('sorting is stable on ties via the id tiebreaker', () {
      final peers = [
        Peer.fromJson({'id': '2', 'hostname': 'same'}),
        Peer.fromJson({'id': '1', 'hostname': 'same'}),
      ];

      const PeerSortOrder(PeerSortType.remoteHost).apply(peers);

      expect(peers.map((p) => p.id).toList(), ['1', '2']);
    });
  });

  group('peer filtering', () {
    final peers = [
      Peer.fromJson({'id': '111', 'alias': 'Studio Mac', 'hostname': 'mac'}),
      Peer.fromJson({'id': '222', 'hostname': 'pixel', 'username': 'ada'}),
    ];

    test('an empty query returns everything', () {
      expect(filterPeers(peers, '').length, 2);
      expect(filterPeers(peers, '   ').length, 2);
    });

    test('matches id, alias, hostname and username case-insensitively', () {
      expect(filterPeers(peers, '111').single.id, '111');
      expect(filterPeers(peers, 'studio').single.id, '111');
      expect(filterPeers(peers, 'PIXEL').single.id, '222');
      expect(filterPeers(peers, 'ada').single.id, '222');
    });

    test('a non-matching query returns nothing', () {
      expect(filterPeers(peers, 'nothing'), isEmpty);
    });
  });

  group('service status', () {
    test('maps the status_num contract', () {
      expect(connectStatusFrom(-1), ConnectStatus.connecting);
      expect(connectStatusFrom(0), ConnectStatus.disconnected);
      expect(connectStatusFrom(1), ConnectStatus.connected);
      expect(connectStatusFrom(42), ConnectStatus.unknown);
    });

    test('unknown verification methods fall back to both', () {
      expect(normalizeVerificationMethod(kUsePermanentPassword),
          kUsePermanentPassword);
      expect(normalizeVerificationMethod(kUseTemporaryPassword),
          kUseTemporaryPassword);
      expect(normalizeVerificationMethod(''), kUseBothPasswords);
      expect(normalizeVerificationMethod('nonsense'), kUseBothPasswords);
    });

    test('unknown password lengths fall back to 6', () {
      expect(normalizeTemporaryPasswordLength('8'), '8');
      expect(normalizeTemporaryPasswordLength('10'), '10');
      expect(normalizeTemporaryPasswordLength(''), '6');
      expect(normalizeTemporaryPasswordLength('7'), '6');
    });

    test('the initial snapshot is explicitly not loaded', () {
      const status = ServiceStatus.initial();

      expect(status.isLoaded, isFalse);
      expect(status.deviceId, isEmpty);
      expect(status.connectStatus, ConnectStatus.unknown);
      expect(status.hasError, isFalse);
    });

    test('copyWith can both set and clear the error', () {
      const base = ServiceStatus.initial();

      final failed = base.copyWith(error: 'boom');
      expect(failed.hasError, isTrue);
      // Stale values are retained alongside the error.
      expect(failed.deviceId, base.deviceId);

      expect(failed.copyWith(clearError: true).hasError, isFalse);
    });

    test('equality covers the fields the UI renders', () {
      const a = ServiceStatus.initial();
      final b = a.copyWith(deviceId: '123');

      expect(a == a.copyWith(), isTrue);
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });
  });

  group('account payloads', () {
    test('parses the hbbs user shape', () {
      final user = UserPayload.fromJson({
        'name': 'ada',
        'display_name': 'Ada L',
        'avatar': 'http://example/a.png',
        'is_admin': true,
        'status': 1,
      });

      expect(user.name, 'ada');
      expect(user.displayNameOrName, 'Ada L');
      expect(user.isAdmin, isTrue);
      expect(user.status, UserStatus.normal);
    });

    test('maps the status discriminants both ways', () {
      expect(userStatusFromJson(0), UserStatus.disabled);
      expect(userStatusFromJson(-1), UserStatus.unverified);
      expect(userStatusFromJson(1), UserStatus.normal);
      expect(userStatusFromJson(null), UserStatus.normal);

      expect(userStatusToJson(UserStatus.disabled), 0);
      expect(userStatusToJson(UserStatus.unverified), -1);
      expect(userStatusToJson(UserStatus.normal), 1);
    });

    test('falls back to the handle when no display name is set', () {
      final user = UserPayload.fromJson({'name': 'ada', 'display_name': '  '});
      expect(user.displayNameOrName, 'ada');
    });

    test('the user payload survives a json round trip', () {
      final user = UserPayload.fromJson({
        'name': 'ada',
        'display_name': 'Ada L',
        'avatar': 'a.png',
        'status': -1,
      });

      final decoded =
          UserPayload.fromJson(jsonDecode(jsonEncode(user.toJson())));

      expect(decoded.name, user.name);
      expect(decoded.displayName, user.displayName);
      expect(decoded.status, UserStatus.unverified);
    });

    test('share rules gate write and manage', () {
      expect(ShareRule.canWrite(ShareRule.read), isFalse);
      expect(ShareRule.canWrite(ShareRule.readWrite), isTrue);
      expect(ShareRule.canManage(ShareRule.readWrite), isFalse);
      expect(ShareRule.canManage(ShareRule.fullControl), isTrue);
    });
  });
}
