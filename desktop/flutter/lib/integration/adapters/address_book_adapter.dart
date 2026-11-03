import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/adapters/account_adapter.dart';
import 'package:flutter_hbb/integration/adapters/account_types.dart';
import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';

/// Reserved address book names. Persisted verbatim in the cache.
const String kPersonalAddressBookName = 'My address book';
const String kLegacyAddressBookName = 'Legacy address book';

/// One address book and its peers.
@immutable
class AddressBook {
  const AddressBook({
    required this.name,
    required this.guid,
    required this.peers,
    required this.tags,
    required this.tagColors,
  });

  final String name;

  /// Empty for the legacy address book, which predates guids.
  final String guid;

  final List<Peer> peers;
  final List<String> tags;

  /// Tag name to ARGB color.
  final Map<String, int> tagColors;

  bool get isPersonal => name == kPersonalAddressBookName;

  bool get isLegacy => name == kLegacyAddressBookName;
}

/// Read-only view of the cached address books.
///
/// Milestone 0 reads only the on-disk cache written by the legacy sync
/// (`mainLoadAb`). Pulling from the server, and every mutation, arrives with
/// Milestone 1. Loading a cache whose token does not match the current
/// session is treated as no data, matching the legacy guard.
class AddressBookAdapter extends ChangeNotifier {
  AddressBookAdapter({OptionRepository? optionRepository})
      : _options = optionRepository ?? OptionRepository.instance;

  static final AddressBookAdapter instance = AddressBookAdapter();

  final OptionRepository _options;

  Map<String, AddressBook> _books = const {};
  String _currentName = '';
  bool _isLoaded = false;
  Object? _error;

  /// Address books by name.
  Map<String, AddressBook> get books => Map.unmodifiable(_books);

  List<String> get names => _books.keys.toList();

  bool get isLoaded => _isLoaded;

  Object? get error => _error;

  bool get hasError => _error != null;

  /// True when the cache contains a legacy address book.
  bool get isLegacyMode => _books.containsKey(kLegacyAddressBookName);

  /// The selected address book, restored from `current-ab-name`.
  AddressBook? get current => _books[_currentName];

  String get currentName => _currentName;

  List<Peer> get currentPeers => current?.peers ?? const [];

  Peer? find(String id) {
    for (final peer in currentPeers) {
      if (peer.id == id) return peer;
    }
    return null;
  }

  /// Tags on [id] in the current address book.
  List<dynamic> tagsOf(String id) => find(id)?.tags ?? const [];

  /// Select an address book by name. Ignored when the name is unknown.
  void select(String name) {
    if (!_books.containsKey(name) || _currentName == name) return;
    _currentName = name;
    notifyListeners();
  }

  /// Read the cached address books.
  Future<void> load() async {
    try {
      final token = _options.getLocalString(kLocalOptionAccessToken);
      if (token.isEmpty) {
        _books = const {};
        _currentName = '';
        _isLoaded = true;
        _error = null;
        notifyListeners();
        return;
      }

      final raw = await bind.mainLoadAb();
      final data = raw.isEmpty ? null : jsonDecode(raw);
      // A cache written under a different login is not ours to show.
      if (data is! Map<String, dynamic> ||
          data['access_token'] != token) {
        _books = const {};
        _currentName = '';
        _isLoaded = true;
        _error = null;
        notifyListeners();
        return;
      }

      _books = _decodeBooks(data['ab_entries']);
      _restoreCurrent();
      _error = null;
    } catch (e, s) {
      debugPrint('failed to load the address book cache: $e');
      debugPrintStack(stackTrace: s);
      _error = e;
    }
    _isLoaded = true;
    notifyListeners();
  }

  Map<String, AddressBook> _decodeBooks(dynamic entries) {
    if (entries is! List) return const {};
    final books = <String, AddressBook>{};
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) continue;
      final name = entry['name'];
      if (name is! String || name.isEmpty) continue;
      final guid = entry['guid'] is String ? entry['guid'] as String : '';
      // Only the legacy book may omit a guid.
      if (guid.isEmpty && name != kLegacyAddressBookName) continue;

      books[name] = AddressBook(
        name: name,
        guid: guid,
        peers: _decodePeers(entry['peers']),
        tags: entry['tags'] is List
            ? (entry['tags'] as List).map((e) => e.toString()).toList()
            : const [],
        tagColors: _decodeTagColors(entry['tag_colors']),
      );
    }
    return books;
  }

  List<Peer> _decodePeers(dynamic peers) {
    if (peers is! List) return const [];
    final res = <Peer>[];
    for (final peer in peers) {
      if (peer is Map<String, dynamic>) res.add(Peer.fromJson(peer));
    }
    return res;
  }

  Map<String, int> _decodeTagColors(dynamic raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return Map<String, int>.from(decoded);
    } catch (e) {
      debugPrint('failed to decode tag colors: $e');
      return const {};
    }
  }

  void _restoreCurrent() {
    final last = bind.getLocalFlutterOption(k: kOptionCurrentAbName);
    if (_books.containsKey(last)) {
      _currentName = last;
    } else if (_books.containsKey(kPersonalAddressBookName)) {
      _currentName = kPersonalAddressBookName;
    } else {
      _currentName = _books.keys.isEmpty ? '' : _books.keys.first;
    }
  }
}

/// Read-only view of the cached device groups.
///
/// Like [AddressBookAdapter], Milestone 0 reads only `mainLoadGroup`.
class GroupAdapter extends ChangeNotifier {
  GroupAdapter({OptionRepository? optionRepository})
      : _options = optionRepository ?? OptionRepository.instance;

  static final GroupAdapter instance = GroupAdapter();

  final OptionRepository _options;

  List<DeviceGroupPayload> _deviceGroups = const [];
  List<UserPayload> _users = const [];
  List<Peer> _peers = const [];
  bool _isLoaded = false;
  Object? _error;

  List<DeviceGroupPayload> get deviceGroups => List.unmodifiable(_deviceGroups);

  List<UserPayload> get users => List.unmodifiable(_users);

  List<Peer> get peers => List.unmodifiable(_peers);

  bool get isLoaded => _isLoaded;

  Object? get error => _error;

  bool get hasError => _error != null;

  Future<void> load() async {
    try {
      final token = _options.getLocalString(kLocalOptionAccessToken);
      if (token.isEmpty) {
        _clear();
        _isLoaded = true;
        _error = null;
        notifyListeners();
        return;
      }

      final raw = await bind.mainLoadGroup();
      final data = raw.isEmpty ? null : jsonDecode(raw);
      if (data is! Map<String, dynamic> || data['access_token'] != token) {
        _clear();
        _isLoaded = true;
        _error = null;
        notifyListeners();
        return;
      }

      _deviceGroups = _decodeList(
          data['device_groups'], (m) => DeviceGroupPayload.fromJson(m));
      _users = _decodeList(data['users'], (m) => UserPayload.fromJson(m));
      _peers = _decodeList(data['peers'], (m) => Peer.fromJson(m));
      _error = null;
    } catch (e, s) {
      debugPrint('failed to load the group cache: $e');
      debugPrintStack(stackTrace: s);
      _error = e;
    }
    _isLoaded = true;
    notifyListeners();
  }

  List<T> _decodeList<T>(
      dynamic raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw is! List) return const [];
    final res = <T>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) res.add(fromJson(item));
    }
    return res;
  }

  void _clear() {
    _deviceGroups = const [];
    _users = const [];
    _peers = const [];
  }
}
