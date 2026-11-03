import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/adapters/account_types.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';

/// Local option keys owned by the account layer.
const String kLocalOptionAccessToken = 'access_token';
const String kLocalOptionUserInfo = 'user_info';

/// Read-only view of the signed-in RustDesk account.
///
/// Milestone 0 reads the cached local user info written by the legacy login
/// flow. It deliberately does not perform the `/api/currentUser` round trip or
/// any mutation; sign-in, sign-out and refresh arrive with Milestone 4.
class AccountAdapter extends ChangeNotifier {
  AccountAdapter({OptionRepository? optionRepository})
      : _options = optionRepository ?? OptionRepository.instance;

  static final AccountAdapter instance = AccountAdapter();

  final OptionRepository _options;

  UserPayload? _user;
  bool _isLoaded = false;
  Object? _error;

  /// The cached account, or null when signed out.
  UserPayload? get user => _user;

  /// False until [load] has run once.
  bool get isLoaded => _isLoaded;

  Object? get error => _error;

  bool get hasError => _error != null;

  /// True when an access token is present. The token's validity is only known
  /// after a server round trip, which Milestone 0 does not perform.
  bool get isSignedIn => accessToken.isNotEmpty;

  /// Whether account features are disabled by the build.
  bool get isAccountDisabled => bind.isDisableAccount();

  String get accessToken => _options.getLocalString(kLocalOptionAccessToken);

  String get displayName => _user?.displayNameOrName ?? '';

  String get avatar => _user?.avatar ?? '';

  bool get isAdmin => _user?.isAdmin ?? false;

  /// A label like `Ada (@ada)` when the display name differs from the handle.
  String get accountLabelWithHandle {
    final user = _user;
    if (user == null) return '';
    final username = user.name.trim();
    if (username.isEmpty) return '';
    final preferred = user.displayName.trim();
    if (preferred.isEmpty || preferred == username) return username;
    return '$preferred (@$username)';
  }

  /// Read the locally cached account info.
  Future<void> load() async {
    if (isAccountDisabled) {
      _user = null;
      _isLoaded = true;
      _error = null;
      notifyListeners();
      return;
    }
    try {
      _user = _readLocalUser();
      _error = null;
    } catch (e) {
      debugPrint('failed to read the local user info: $e');
      _user = null;
      _error = e;
    }
    _isLoaded = true;
    notifyListeners();
  }

  UserPayload? _readLocalUser() {
    final raw = _options.getLocalString(kLocalOptionUserInfo);
    if (raw.isEmpty) return null;
    final decoded = json.decode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    return UserPayload.fromJson(decoded);
  }
}
