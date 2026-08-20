import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/adapters/plugin_adapter.dart';
import 'package:flutter_hbb/integration/adapters/printer_adapter.dart';
import 'package:flutter_hbb/integration/adapters/service_status_adapter.dart';
import 'package:flutter_hbb/integration/adapters/two_factor_adapter.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/platform/platform_features.dart';

export 'package:flutter_hbb/integration/adapters/plugin_adapter.dart'
    show PluginInfo;
export 'package:flutter_hbb/integration/adapters/printer_adapter.dart'
    show IncomingJobAction, OutgoingPrinterState, PrinterOptions;
export 'package:flutter_hbb/integration/adapters/two_factor_adapter.dart'
    show TrustedDevice;

/// Which settings page a deep link opens.
///
/// Ported from `SettingsTabKey` in
/// `flutter_legacy/lib/desktop/pages/desktop_setting_page.dart`. The names are
/// the existing deep-link contract.
enum SettingsTab {
  general,
  safety,
  network,
  display,
  plugin,
  account,
  printer,
  about,
}

/// One switch on a settings page.
///
/// Every switch is backed by a real option key, so this carries the key rather
/// than a local bool. [scope] decides which store it reads and writes: the
/// synced config or the per-install local config.
enum SettingScope { config, local }

@immutable
class SettingToggle {
  const SettingToggle({
    required this.key,
    required this.label,
    required this.description,
    this.scope = SettingScope.config,
    this.supportedOn,
  });

  final String key;
  final String label;
  final String description;
  final SettingScope scope;

  /// Platforms this option applies to. Null means every platform.
  final bool Function()? supportedOn;

  bool get isSupported => supportedOn?.call() ?? true;
}

/// A switch's current value and why it may not be editable.
@immutable
class ToggleState {
  const ToggleState({
    required this.toggle,
    required this.value,
    required this.lock,
  });

  final SettingToggle toggle;
  final bool value;
  final OptionLock lock;

  bool get isEditable => lock == OptionLock.none;

  /// What to tell the user when they cannot change this.
  String? get lockReason {
    switch (lock) {
      case OptionLock.none:
        return null;
      case OptionLock.fixed:
        return 'Managed by your deployment';
      case OptionLock.managed:
        return 'Hidden by your deployment';
      case OptionLock.unsupported:
        return 'Not available on this platform';
    }
  }
}

/// Backs the settings surface with real options.
///
/// Reads and writes the existing option keys through [OptionRepository], so a
/// setting persists across restart and honours a deployment's fixed or hidden
/// options. Nothing here keeps a local copy of a value the core owns.
class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel({
    OptionRepository? options,
    ServiceStatusAdapter? serviceStatus,
    TwoFactorAdapter? twoFactor,
    PrinterAdapter? printer,
    PluginAdapter? plugins,
  })  : _options = options ?? OptionRepository.instance,
        _service = serviceStatus ?? ServiceStatusAdapter.instance,
        _twoFactor = twoFactor ?? TwoFactorAdapter.instance,
        _printer = printer ?? PrinterAdapter.instance,
        _plugins = plugins ?? PluginAdapter.instance;

  final OptionRepository _options;
  final ServiceStatusAdapter _service;
  final TwoFactorAdapter _twoFactor;
  final PrinterAdapter _printer;
  final PluginAdapter _plugins;

  // ------------------------------------------------------------- the toggles

  /// Security switches, mapped to the keys the core already uses.
  static const securityToggles = [
    SettingToggle(
      key: kOptionEnableKeyboard,
      label: 'Keyboard and mouse',
      description: 'Let people who connect control this device.',
    ),
    SettingToggle(
      key: kOptionEnableClipboard,
      label: 'Clipboard',
      description: 'Share clipboard contents with the connected device.',
    ),
    SettingToggle(
      key: kOptionEnableFileTransfer,
      label: 'File transfer',
      description: 'Allow files to be sent and received.',
    ),
    SettingToggle(
      key: kOptionEnableAudio,
      label: 'Audio',
      description: 'Share this device\'s audio.',
    ),
    SettingToggle(
      key: kOptionEnableTerminal,
      label: 'Terminal',
      description: 'Allow a remote shell on this device.',
    ),
    SettingToggle(
      key: kOptionEnableRemoteRestart,
      label: 'Remote restart',
      description: 'Allow restarting this device remotely.',
    ),
    SettingToggle(
      key: kOptionEnableBlockInput,
      label: 'Block local input',
      description: 'Let the controller disable this device\'s keyboard.',
    ),
  ];

  /// Network switches.
  static const networkToggles = [
    SettingToggle(
      key: kOptionEnableLanDiscovery,
      label: 'LAN discovery',
      description: 'Let devices on this network find this one.',
    ),
    SettingToggle(
      key: kOptionDirectServer,
      label: 'Direct connections',
      description: 'Accept connections without going through a relay.',
    ),
    SettingToggle(
      key: kOptionForceAlwaysRelay,
      label: 'Always relay',
      description: 'Route every connection through a relay server.',
    ),
    SettingToggle(
      key: kOptionAllowWebSocket,
      label: 'WebSocket',
      description: 'Connect over WebSocket where TCP is blocked.',
    ),
    SettingToggle(
      key: kOptionEnableUdpPunch,
      label: 'UDP hole punching',
      description: 'Try a direct path before falling back to a relay.',
    ),
  ];

  /// Workspace switches, stored per install rather than synced.
  static const workspaceToggles = [
    SettingToggle(
      key: kOptionOpenNewConnInTabs,
      label: 'Open connections in tabs',
      description: 'Reuse one window instead of opening a new one.',
      scope: SettingScope.local,
    ),
    SettingToggle(
      key: kOptionEnableConfirmClosingTabs,
      label: 'Confirm before closing',
      description: 'Ask before closing a window with live sessions.',
      scope: SettingScope.local,
    ),
    SettingToggle(
      key: kOptionEnableCheckUpdate,
      label: 'Check for updates',
      description: 'Look for new versions automatically.',
      scope: SettingScope.local,
    ),
    SettingToggle(
      key: kOptionAllowAutoRecordOutgoing,
      label: 'Record outgoing sessions',
      description: 'Start recording whenever you connect to a device.',
      scope: SettingScope.local,
    ),
  ];

  /// Display switches.
  static const displayToggles = [
    SettingToggle(
      key: kOptionShowRemoteCursor,
      label: 'Show the remote cursor',
      description: 'Draw the other device\'s pointer on the canvas.',
    ),
    SettingToggle(
      key: kOptionShowQualityMonitor,
      label: 'Quality monitor',
      description: 'Show bandwidth and latency during a session.',
    ),
    SettingToggle(
      key: kOptionEnableAbr,
      label: 'Adaptive bitrate',
      description: 'Lower quality automatically on a slow link.',
    ),
    SettingToggle(
      key: kOptionEnableHwcodec,
      label: 'Hardware codec',
      description: 'Use the GPU to encode and decode video.',
    ),
    SettingToggle(
      key: kOptionDirectxCapture,
      label: 'DirectX capture',
      description: 'Capture the screen through DirectX.',
      supportedOn: _isWindows,
    ),
    SettingToggle(
      key: kOptionAllowRemoveWallpaper,
      label: 'Hide the wallpaper',
      description: 'Remove the desktop background during a session.',
      supportedOn: _isWindowsOrLinux,
    ),
  ];

  static bool _isWindows() => isWindows;
  static bool _isWindowsOrLinux() => isWindows || isLinux;

  /// Whether the whole Access page applies.
  ///
  /// Every permission there governs what someone connecting *to* this device
  /// may do; a build that cannot be controlled has nothing to permit.
  bool get hasIncomingPermissions => PlatformFeatures.canBeControlled;

  /// Whether the workspace can start and stop sharing.
  bool get hasService => PlatformFeatures.hasService;

  /// Whether this build opens sessions in their own windows.
  bool get hasMultipleWindows => PlatformFeatures.hasMultipleWindows;

  // -------------------------------------------------------------- reading

  /// The current value and lock state of [toggle].
  ToggleState stateOf(SettingToggle toggle) {
    if (!toggle.isSupported) {
      return ToggleState(
        toggle: toggle,
        value: false,
        lock: OptionLock.unsupported,
      );
    }
    final value = toggle.scope == SettingScope.local
        ? _options.getLocalBool(toggle.key)
        : _options.getBool(toggle.key);
    return ToggleState(
      toggle: toggle,
      value: value,
      // Local options are per-install, so a deployment cannot pin them.
      lock: toggle.scope == SettingScope.local
          ? OptionLock.none
          : _options.lockFor(toggle.key),
    );
  }

  List<ToggleState> statesOf(List<SettingToggle> toggles) =>
      [for (final toggle in toggles) stateOf(toggle)];

  /// Flip [toggle]. Returns false when it is locked, so the UI can say why
  /// rather than showing a switch that silently springs back.
  Future<bool> toggle(SettingToggle option) async {
    final state = stateOf(option);
    if (!state.isEditable) return false;
    if (option.scope == SettingScope.local) {
      await _options.setLocalBool(option.key, !state.value);
    } else {
      await _options.setBool(option.key, !state.value);
    }
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------------- identity

  String get deviceId => _service.status.deviceId;

  String get temporaryPassword => _service.status.temporaryPassword;

  String get verificationMethod => _service.status.verificationMethod;

  String get temporaryPasswordLength => _service.status.temporaryPasswordLength;

  bool get isServiceRunning => _service.status.isServiceRunning;

  /// Whether the deployment forbids changing the permanent password.
  bool get isPasswordChangeDisabled =>
      _options.isChangePermanentPasswordDisabled;

  bool get isServerSettingHidden => _options.isServerSettingHidden;

  bool get isProxySettingHidden => _options.isProxySettingHidden;

  bool get isNetworkSettingHidden => _options.isNetworkSettingHidden;

  bool get isSecuritySettingHidden => _options.isSecuritySettingHidden;

  // ---------------------------------------------------------------- writes

  /// Set the permanent password. Returns false when the core refused it.
  Future<bool> setPermanentPassword(String password) async {
    if (isPasswordChangeDisabled) return false;
    try {
      return await bind.mainSetPermanentPasswordWithResult(
          password: password);
    } catch (e) {
      debugPrint('failed to set the permanent password: $e');
      return false;
    }
  }

  Future<void> setVerificationMethod(String method) async {
    await _options.setString(kOptionVerificationMethod, method);
    await _service.refresh();
    notifyListeners();
  }

  Future<void> setTemporaryPasswordLength(String length) async {
    await _options.setString(kOptionTemporaryPasswordLength, length);
    await _service.refresh();
    notifyListeners();
  }

  /// The ID, relay, API server and key, as the core has them.
  Future<ServerConfig> serverConfig() async => ServerConfig(
        idServer: await _options.getStringAsync('custom-rendezvous-server'),
        relayServer: await _options.getStringAsync('relay-server'),
        apiServer: await _options.getStringAsync('api-server'),
        key: await _options.getStringAsync('key'),
      );

  /// Write the server configuration.
  ///
  /// The keys are the existing config names; renaming one points the client
  /// at the wrong server.
  Future<void> setServerConfig(ServerConfig config) async {
    await _options.setString(
        'custom-rendezvous-server', config.idServer.trim());
    await _options.setString('relay-server', config.relayServer.trim());
    await _options.setString('api-server', config.apiServer.trim());
    await _options.setString('key', config.key.trim());
    notifyListeners();
  }

  // ----------------------------------------------------------------- proxy

  /// Whether a custom client pinned the proxy, making it read-only.
  ///
  /// `proxy-url` is not a stored option; the legacy dialog passes that name to
  /// `mainIsOptionFixed` purely to ask whether the deployment locked it.
  bool get isProxyFixed => _options.isFixed(kOptionProxyUrl);

  /// Whether a proxy is configured and reachable.
  Future<bool> isProxyActive() async {
    try {
      return await bind.mainGetProxyStatus();
    } catch (e) {
      debugPrint('failed to read the proxy status: $e');
      return false;
    }
  }

  /// Check a proxy address with the core before saving it.
  ///
  /// Returns null when the address is usable, otherwise the core's translation
  /// key for the problem. The scheme is stripped first because the core tests a
  /// host and port, matching the legacy dialog. `testWithProxy: false` keeps
  /// the check from being routed through the proxy being replaced.
  Future<String?> validateProxyAddress(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;
    final hostPort =
        trimmed.contains('://') ? trimmed.split('://')[1] : trimmed;
    try {
      final message = await bind.mainTestIfValidServer(
          server: hostPort, testWithProxy: false);
      return message.isEmpty ? null : message;
    } catch (e) {
      debugPrint('failed to validate the proxy address: $e');
      return 'Invalid address';
    }
  }

  /// The configured SOCKS5 proxy.
  ///
  /// The core returns a three-element list: address, username, password. A
  /// shorter list means nothing is configured.
  Future<ProxyConfig> proxyConfig() async {
    try {
      final socks = await bind.mainGetSocks();
      if (socks.length < 3) return const ProxyConfig();
      return ProxyConfig(
        address: socks[0],
        username: socks[1],
        password: socks[2],
      );
    } catch (e) {
      debugPrint('failed to read the proxy: $e');
      return const ProxyConfig();
    }
  }

  /// Save the proxy. An empty address clears it.
  ///
  /// Returns false when the deployment pinned the proxy, so the UI can say why
  /// instead of reporting a write that never happened. The fields are trimmed
  /// the way the legacy dialog trimmed them, including the password.
  Future<bool> setProxyConfig(ProxyConfig config) async {
    if (isProxyFixed) return false;
    await bind.mainSetSocks(
      proxy: config.address.trim(),
      username: config.username.trim(),
      password: config.password.trim(),
    );
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------------- two-factor

  /// Whether two-factor authentication is set up on this device.
  bool get isTwoFactorEnabled => _twoFactor.isEnabled;

  /// Whether a Telegram bot delivers the verification codes.
  bool get hasTelegramBot => _twoFactor.hasBot;

  /// Whether trusted devices may skip 2FA. Off unless 2FA is on.
  bool get areTrustedDevicesEnabled =>
      isTwoFactorEnabled && _options.getBool(kOptionEnableTrustedDevices);

  /// The enrolment URI to show as a QR code while turning 2FA on.
  Future<String> generateTwoFactorSecret() =>
      _twoFactor.generateSecret();

  /// The typed-in form of an enrolment URI's secret.
  String twoFactorSecretOf(String enrolmentUri) =>
      TwoFactorAdapter.secretOf(enrolmentUri);

  /// Finish enrolment. Returns false when the core rejected the code, which
  /// leaves 2FA off.
  Future<bool> verifyTwoFactor(String code) async {
    final ok = await _twoFactor.verify(code);
    if (ok) notifyListeners();
    return ok;
  }

  /// Turn 2FA off, which also drops every trusted device.
  Future<void> disableTwoFactor() async {
    await _twoFactor.disable();
    notifyListeners();
  }

  /// Register a Telegram bot token. Returns null on success, otherwise the
  /// core's message.
  Future<String?> verifyTelegramBot(String token) async {
    final error = await _twoFactor.verifyBot(token);
    if (error == null) notifyListeners();
    return error;
  }

  Future<void> removeTelegramBot() async {
    await _twoFactor.removeBot();
    notifyListeners();
  }

  /// Allow or stop devices being trusted after they verify.
  ///
  /// Turning it off clears the devices already trusted; leaving them would
  /// keep letting them skip 2FA.
  Future<void> setTrustedDevicesEnabled(bool enabled) async {
    await _options.setBool(kOptionEnableTrustedDevices, enabled);
    if (!enabled) await _twoFactor.clearTrustedDevices();
    notifyListeners();
  }

  Future<List<TrustedDevice>> trustedDevices() => _twoFactor.trustedDevices();

  Future<void> removeTrustedDevices(
    List<TrustedDevice> devices, {
    required int total,
  }) async {
    await _twoFactor.removeTrustedDevices(devices, total: total);
    notifyListeners();
  }

  // --------------------------------------------------------------- printer

  /// Whether the deployment hides remote printing, or this platform has no
  /// virtual printer driver to begin with.
  bool get isPrinterSettingHidden =>
      _printer.isHidden || !PlatformFeatures.hasRemotePrinter;

  /// Whether incoming print jobs are accepted at all.
  bool get isRemotePrinterEnabled =>
      _options.getBool(kOptionEnableRemotePrinter);

  Future<void> setRemotePrinterEnabled(bool enabled) async {
    await _options.setBool(kOptionEnableRemotePrinter, enabled);
    notifyListeners();
  }

  /// Why outgoing printing is or is not available on this device.
  OutgoingPrinterState get outgoingPrinterState => _printer.outgoingState;

  /// The core's message when installing the virtual printer failed.
  String get printerInstallError => _printer.installError;

  String get appName => _printer.appName;

  Future<void> installPrinter() async {
    await _printer.installPrinter();
    notifyListeners();
  }

  Future<PrinterOptions> printerOptions() => _printer.options();

  Future<void> setIncomingJobAction(IncomingJobAction action) async {
    await _printer.setAction(action);
    notifyListeners();
  }

  Future<void> setSelectedPrinter(String name) async {
    await _printer.setPrinterName(name);
    notifyListeners();
  }

  Future<void> setPrinterAutoPrint(bool enabled) async {
    await _printer.setAutoPrint(enabled);
    notifyListeners();
  }

  // --------------------------------------------------------------- plugins

  /// Whether this build supports plugins at all.
  ///
  /// The core answers for the build flavour; the platform check keeps the web
  /// build out, where a plugin has nothing to load into.
  bool get isPluginFeatureEnabled =>
      PlatformFeatures.hasPlugins && _plugins.isFeatureEnabled;

  bool get arePluginsLoaded => _plugins.isLoaded;

  /// Why the core could not load the plugin list, if it could not.
  String get pluginFailedReason => _plugins.failedReason;

  List<PluginInfo> get plugins => _plugins.plugins;

  /// Subscribe to plugin events and ask the core for the list.
  Future<void> loadPlugins() => _plugins.load();

  bool isPluginEnabled(String id) => _plugins.isEnabled(id);

  Future<void> installPlugin(PluginInfo plugin) => _plugins.install(plugin);

  Future<void> uninstallPlugin(PluginInfo plugin) =>
      _plugins.uninstall(plugin);

  void setPluginEnabled(PluginInfo plugin, bool enabled) {
    _plugins.setEnabled(plugin, enabled);
    notifyListeners();
  }

  /// Notified whenever the plugin list changes, so a view can rebuild without
  /// polling.
  Listenable get pluginChanges => _plugins;

  // ----------------------------------------------------------------- about

  Future<String> version() async {
    try {
      return await bind.mainGetVersion();
    } catch (e) {
      debugPrint('failed to read the version: $e');
      return '';
    }
  }

  Future<String> fingerprint() async {
    try {
      return await bind.mainGetFingerprint();
    } catch (e) {
      debugPrint('failed to read the fingerprint: $e');
      return '';
    }
  }

  Future<String> license() async {
    try {
      return await bind.mainGetLicense();
    } catch (e) {
      debugPrint('failed to read the license: $e');
      return '';
    }
  }
}

/// A SOCKS5 proxy.
@immutable
class ProxyConfig {
  const ProxyConfig({
    this.address = '',
    this.username = '',
    this.password = '',
  });

  /// Host and port, e.g. `socks5://127.0.0.1:1080`. Empty means no proxy.
  final String address;
  final String username;
  final String password;

  bool get isSet => address.isNotEmpty;

  ProxyConfig copyWith({String? address, String? username, String? password}) =>
      ProxyConfig(
        address: address ?? this.address,
        username: username ?? this.username,
        password: password ?? this.password,
      );
}

/// The ID, relay and API servers this client uses.
@immutable
class ServerConfig {
  const ServerConfig({
    this.idServer = '',
    this.relayServer = '',
    this.apiServer = '',
    this.key = '',
  });

  /// Read a shared configuration string, as a QR code or a paste carries it.
  ///
  /// Two encodings exist: plain JSON from older shares, and the reversed
  /// base64 [encode] produces. The JSON keys are short (`host`, `relay`) and
  /// are the server's contract, not this model's field names.
  ///
  /// Throws when [payload] is neither, so a caller can tell the user the code
  /// was not a RustDesk configuration.
  factory ServerConfig.decode(String payload) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      final reversed = payload.split('').reversed.join();
      final bytes = base64Decode(base64.normalize(reversed));
      json = jsonDecode(utf8.decode(bytes, allowMalformed: true))
          as Map<String, dynamic>;
    }
    return ServerConfig(
      idServer: json['host']?.toString() ?? '',
      relayServer: json['relay']?.toString() ?? '',
      apiServer: json['api']?.toString() ?? '',
      key: json['key']?.toString() ?? '',
    );
  }

  /// The prefix a RustDesk configuration QR code carries.
  static const String qrPrefix = 'config=';

  /// Read a scanned QR code, or null when it is not a configuration.
  ///
  /// A phone camera picks up every code in view, so an unrelated one has to
  /// be rejected rather than parsed into an empty configuration.
  static ServerConfig? fromQrCode(String scanned) {
    if (!scanned.startsWith(qrPrefix)) return null;
    try {
      return ServerConfig.decode(scanned.substring(qrPrefix.length));
    } catch (e) {
      debugPrint('failed to read a scanned configuration: $e');
      return null;
    }
  }

  final String idServer;
  final String relayServer;
  final String apiServer;
  final String key;

  /// This configuration as a shareable string.
  ///
  /// The reversal is not obfuscation for its own sake — it is the format the
  /// server and every other RustDesk client already produce and read.
  String encode() {
    final config = {
      'host': idServer.trim(),
      'relay': relayServer.trim(),
      'api': apiServer.trim(),
      'key': key.trim(),
    };
    return base64UrlEncode(utf8.encode(jsonEncode(config)))
        .split('')
        .reversed
        .join();
  }

  /// The payload to put in a QR code for this configuration.
  String toQrCode() => '$qrPrefix${encode()}';

  bool get isEmpty =>
      idServer.isEmpty &&
      relayServer.isEmpty &&
      apiServer.isEmpty &&
      key.isEmpty;

  ServerConfig copyWith({
    String? idServer,
    String? relayServer,
    String? apiServer,
    String? key,
  }) =>
      ServerConfig(
        idServer: idServer ?? this.idServer,
        relayServer: relayServer ?? this.relayServer,
        apiServer: apiServer ?? this.apiServer,
        key: key ?? this.key,
      );
}
