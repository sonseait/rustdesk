import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// Why an option cannot be changed by the user.
enum OptionLock {
  /// The option is editable.
  none,

  /// Pinned by the deployment config (`mainIsOptionFixed`).
  fixed,

  /// Hidden or disabled by a buildin option in a custom client.
  managed,

  /// Not applicable on this platform.
  unsupported,
}

/// A resolved option value together with why it may not be editable.
@immutable
class OptionState<T> {
  const OptionState({required this.value, required this.lock});

  final T value;
  final OptionLock lock;

  bool get isEditable => lock == OptionLock.none;

  @override
  bool operator ==(Object other) =>
      other is OptionState<T> && other.value == value && other.lock == lock;

  @override
  int get hashCode => Object.hash(value, lock);

  @override
  String toString() => 'OptionState($value, lock: $lock)';
}

/// Reads and writes the existing RustDesk option keys.
///
/// This is the single writable surface over `bind.main*Option*`. It preserves
/// the legacy string/bool encoding exactly, including the custom-client
/// defaults and the deliberate asymmetry in [bool2option] for the UDP/IPv6
/// punch keys.
///
/// Three storage scopes exist in the core and are not interchangeable:
/// - **config** (`mainGetOption`): synced RustDesk config.
/// - **local** (`mainGetLocalOption`): per-install UI state.
/// - **buildin** (`mainGetBuildinOption`): read-only deployment policy.
class OptionRepository {
  OptionRepository({RustdeskImpl? bindOverride}) : _bindOverride = bindOverride;

  static final OptionRepository instance = OptionRepository();

  final RustdeskImpl? _bindOverride;
  bool? _isCustomClient;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  // ---------------------------------------------------------------- defaults

  /// Custom clients persist explicit defaults; the stock client persists ''.
  bool get isCustomClient => _isCustomClient ??= _bind.isCustomClient();

  String get defaultOptionYes => isCustomClient ? 'Y' : '';
  String get defaultOptionNo => isCustomClient ? 'N' : '';
  String get defaultOptionLang => isCustomClient ? 'default' : '';
  String get defaultOptionTheme => isCustomClient ? 'system' : '';
  String get defaultOptionWhitelist => isCustomClient ? ',' : '';
  String get defaultOptionAccessMode => isCustomClient ? 'custom' : '';
  String get defaultOptionApproveMode =>
      isCustomClient ? 'password-click' : '';

  // ---------------------------------------------------------------- encoding

  /// Decode a stored option string to a bool.
  ///
  /// Ported verbatim from `flutter_legacy/lib/common.dart`. The prefix rules
  /// decide what an empty (unset) value means: `enable-*` defaults to on,
  /// `allow-*` defaults to off.
  static bool option2bool(String option, String value) {
    if (option.startsWith('enable-')) {
      return value != 'N';
    }
    if (option.startsWith('allow-') ||
        option == kOptionStopService ||
        option == kOptionDirectServer ||
        option == kOptionForceAlwaysRelay) {
      return value == 'Y';
    }
    // "" is true
    return value != 'N';
  }

  /// Encode a bool to its stored option string.
  ///
  /// Note the asymmetry with [option2bool]: the UDP and IPv6 punch keys are
  /// excluded from the `enable-` branch here but not there. This matches the
  /// legacy behavior and must not be "fixed" without a config migration.
  String bool2option(String option, bool b) {
    if (option.startsWith('enable-') &&
        option != kOptionEnableUdpPunch &&
        option != kOptionEnableIpv6Punch) {
      return b ? defaultOptionYes : 'N';
    }
    if (option.startsWith('allow-') ||
        option == kOptionStopService ||
        option == kOptionDirectServer ||
        option == kOptionForceAlwaysRelay) {
      return b ? 'Y' : defaultOptionNo;
    }
    return b ? 'Y' : 'N';
  }

  // ------------------------------------------------------------ config scope

  String getString(String key) => _bind.mainGetOptionSync(key: key);

  Future<String> getStringAsync(String key) => _bind.mainGetOption(key: key);

  Future<void> setString(String key, String value) =>
      _bind.mainSetOption(key: key, value: value);

  bool getBool(String key) => option2bool(key, getString(key));

  Future<bool> getBoolAsync(String key) async =>
      option2bool(key, await getStringAsync(key));

  Future<void> setBool(String key, bool value) =>
      setString(key, bool2option(key, value));

  // ------------------------------------------------------------- local scope

  String getLocalString(String key) => _bind.mainGetLocalOption(key: key);

  Future<void> setLocalString(String key, String value) =>
      _bind.mainSetLocalOption(key: key, value: value);

  bool getLocalBool(String key) => option2bool(key, getLocalString(key));

  Future<void> setLocalBool(String key, bool value) =>
      setLocalString(key, bool2option(key, value));

  // ----------------------------------------------------------- buildin scope

  /// Read-only deployment policy. Never writable.
  String getBuildin(String key) => _bind.mainGetBuildinOption(key: key);

  bool getBuildinFlag(String key) => getBuildin(key) == 'Y';

  // -------------------------------------------------------------- peer scope

  String getPeerString(String peerId, String key) =>
      _bind.mainGetPeerOptionSync(id: peerId, key: key);

  bool getPeerBool(String peerId, String key) =>
      option2bool(key, getPeerString(peerId, key));

  Future<void> setPeerString(String peerId, String key, String value) =>
      _bind.mainSetPeerOption(id: peerId, key: key, value: value);

  Future<void> setPeerBool(String peerId, String key, bool value) =>
      setPeerString(peerId, key, bool2option(key, value));

  // ------------------------------------------------------------------- locks

  /// True when the deployment pins this option.
  bool isFixed(String key) => _bind.mainIsOptionFixed(key: key);

  /// Why [key] cannot be edited, if it cannot.
  ///
  /// [supported] lets a caller declare platform availability that the core
  /// does not model, e.g. a Windows-only capture option.
  OptionLock lockFor(String key, {bool supported = true}) {
    if (!supported) return OptionLock.unsupported;
    if (isFixed(key)) return OptionLock.fixed;
    if (_isManaged(key)) return OptionLock.managed;
    return OptionLock.none;
  }

  /// Read [key] from the config scope with its lock state.
  OptionState<bool> boolState(String key, {bool supported = true}) =>
      OptionState(
        value: getBool(key),
        lock: lockFor(key, supported: supported),
      );

  /// Read [key] from the config scope with its lock state.
  OptionState<String> stringState(String key, {bool supported = true}) =>
      OptionState(
        value: getString(key),
        lock: lockFor(key, supported: supported),
      );

  /// Write [key] unless it is locked. Returns false when the write was
  /// refused, so the caller can surface that instead of showing a changed
  /// control that silently reverts.
  Future<bool> trySetBool(String key, bool value,
      {bool supported = true}) async {
    if (lockFor(key, supported: supported) != OptionLock.none) return false;
    await setBool(key, value);
    return true;
  }

  /// Write [key] unless it is locked. Returns false when refused.
  Future<bool> trySetString(String key, String value,
      {bool supported = true}) async {
    if (lockFor(key, supported: supported) != OptionLock.none) return false;
    await setString(key, value);
    return true;
  }

  /// Buildin options that hide or disable a settings surface entirely.
  bool _isManaged(String key) {
    switch (key) {
      case kOptionStopService:
        return getBuildinFlag(kOptionHideStopService);
      case kOptionEnableRemotePrinter:
        return getBuildinFlag(kOptionHideRemotePrinterSetting);
      case kOptionAllowWebSocket:
        return getBuildinFlag(kOptionHideWebSocketSetting);
      default:
        return false;
    }
  }

  // -------------------------------------------------------------- convenience

  bool get isChangePermanentPasswordDisabled =>
      getBuildinFlag(kOptionDisableChangePermanentPassword);

  bool get isChangeIdDisabled => getBuildinFlag(kOptionDisableChangeId);

  bool get isUnlockPinDisabled => getBuildinFlag(kOptionDisableUnlockPin);

  bool get isServerSettingHidden => getBuildinFlag(kOptionHideServerSetting);

  bool get isProxySettingHidden => getBuildinFlag(kOptionHideProxySetting);

  bool get isSecuritySettingHidden =>
      getBuildinFlag(kOptionHideSecuritySetting);

  bool get isNetworkSettingHidden => getBuildinFlag(kOptionHideNetworkSetting);

  bool get isRemotePrinterSettingHidden =>
      getBuildinFlag(kOptionHideRemotePrinterSetting);

  /// https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/#whitelist
  bool get whitelistNotEmpty {
    final v = getString(kOptionWhitelist);
    return v != '' && v != ',';
  }

  bool get idWhitelistNotEmpty {
    final v = getString(kOptionIdWhitelist);
    return v != '' && v != ',';
  }

  /// Options the current host platform cannot honor. Used as the `supported`
  /// argument so a control is disabled rather than silently ineffective.
  static bool isSupportedHere(String key) {
    switch (key) {
      case kOptionDirectxCapture:
      case kOptionD3DRender:
        return isWindows;
      case kOptionAllowLinuxHeadless:
        return isLinux;
      case kOptionAllowRemoveWallpaper:
        return isWindows || isLinux;
      default:
        return true;
    }
  }
}

/// The process-wide option repository.
OptionRepository get options => OptionRepository.instance;
