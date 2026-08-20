import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/features/workspace/settings_view_model.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';

/// An in-memory [SettingsViewModel] for widget tests.
///
/// The real model reads and writes through the native bridge, which widget
/// tests do not have. This keeps the values in a map and records writes.
class FakeSettingsViewModel extends SettingsViewModel {
  FakeSettingsViewModel({
    Map<String, bool>? values,
    Map<String, OptionLock>? locks,
    this.passwordChangeDisabled = false,
    this.serverSettingHidden = false,
    this.proxySettingHidden = false,
    this.proxyFixed = false,
  })  : _values = {...?values},
        _locks = {...?locks};

  final Map<String, bool> _values;
  final Map<String, OptionLock> _locks;

  final bool passwordChangeDisabled;
  final bool serverSettingHidden;
  final bool proxySettingHidden;
  final bool proxyFixed;

  /// Keys written, in order.
  final List<String> written = [];

  @override
  ToggleState stateOf(SettingToggle toggle) {
    if (!toggle.isSupported) {
      return ToggleState(
          toggle: toggle, value: false, lock: OptionLock.unsupported);
    }
    return ToggleState(
      toggle: toggle,
      value: _values[toggle.key] ?? false,
      lock: _locks[toggle.key] ?? OptionLock.none,
    );
  }

  @override
  Future<bool> toggle(SettingToggle option) async {
    final state = stateOf(option);
    if (!state.isEditable) return false;
    written.add(option.key);
    _values[option.key] = !state.value;
    notifyListeners();
    return true;
  }

  @override
  bool get isPasswordChangeDisabled => passwordChangeDisabled;

  @override
  bool get isServerSettingHidden => serverSettingHidden;

  /// Whether this build can accept incoming connections. False stands in for
  /// the web build, which has no screen to share.
  bool incomingPermissions = true;

  @override
  bool get hasIncomingPermissions => incomingPermissions;

  @override
  bool get isProxySettingHidden => proxySettingHidden;

  @override
  bool get isProxyFixed => proxyFixed;

  @override
  bool get isNetworkSettingHidden => false;

  @override
  bool get isSecuritySettingHidden => false;

  @override
  String get deviceId => '847293160';

  @override
  String get temporaryPassword => 'abc123';

  @override
  bool get isServiceRunning => true;

  /// Passwords submitted, and whether the core should accept them.
  final List<String> passwords = [];
  bool acceptPassword = true;

  @override
  Future<bool> setPermanentPassword(String password) async {
    if (passwordChangeDisabled) return false;
    passwords.add(password);
    return acceptPassword;
  }

  ServerConfig config = const ServerConfig(
    idServer: 'id.example.com',
    relayServer: 'relay.example.com',
    apiServer: 'https://api.example.com',
    key: 'abc',
  );
  final List<ServerConfig> savedConfigs = [];

  @override
  Future<ServerConfig> serverConfig() async => config;

  @override
  Future<void> setServerConfig(ServerConfig next) async {
    savedConfigs.add(next);
    config = next;
    notifyListeners();
  }

  ProxyConfig proxy = const ProxyConfig();

  /// Proxies saved, in order.
  final List<ProxyConfig> savedProxies = [];

  /// Addresses passed to validation, in order.
  final List<String> validatedProxies = [];

  /// What the core should say about the next address, or null to accept it.
  String? proxyValidationError;

  bool proxyActive = false;

  @override
  Future<ProxyConfig> proxyConfig() async => proxy;

  @override
  Future<bool> isProxyActive() async => proxyActive;

  @override
  Future<String?> validateProxyAddress(String address) async {
    if (address.trim().isEmpty) return null;
    validatedProxies.add(address);
    return proxyValidationError;
  }

  @override
  Future<bool> setProxyConfig(ProxyConfig config) async {
    if (proxyFixed) return false;
    savedProxies.add(config);
    proxy = config;
    proxyActive = config.isSet;
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------------- two-factor

  bool twoFactorEnabled = false;
  bool telegramBot = false;
  bool trustedDevicesEnabled = false;

  /// The enrolment URI the core should hand back, or empty to fail setup.
  String enrolmentUri =
      'otpauth://totp/RustDesk:847293160?secret=JBSWY3DPEHPK3PXP&issuer=RustDesk';

  /// Codes submitted, in order, and whether the core should accept them.
  final List<String> codes = [];
  bool acceptCode = true;

  /// Bot tokens submitted, in order.
  final List<String> botTokens = [];
  String? botError;

  List<TrustedDevice> devices = const [];

  /// Devices removed, in the batches they were removed in.
  final List<List<TrustedDevice>> removedDevices = [];

  @override
  bool get isTwoFactorEnabled => twoFactorEnabled;

  @override
  bool get hasTelegramBot => telegramBot;

  @override
  bool get areTrustedDevicesEnabled =>
      twoFactorEnabled && trustedDevicesEnabled;

  @override
  Future<String> generateTwoFactorSecret() async => enrolmentUri;

  @override
  Future<bool> verifyTwoFactor(String code) async {
    codes.add(code);
    if (!acceptCode) return false;
    twoFactorEnabled = true;
    notifyListeners();
    return true;
  }

  @override
  Future<void> disableTwoFactor() async {
    twoFactorEnabled = false;
    devices = const [];
    notifyListeners();
  }

  @override
  Future<String?> verifyTelegramBot(String token) async {
    botTokens.add(token);
    if (botError != null) return botError;
    telegramBot = true;
    notifyListeners();
    return null;
  }

  @override
  Future<void> removeTelegramBot() async {
    telegramBot = false;
    notifyListeners();
  }

  @override
  Future<void> setTrustedDevicesEnabled(bool enabled) async {
    trustedDevicesEnabled = enabled;
    if (!enabled) devices = const [];
    notifyListeners();
  }

  @override
  Future<List<TrustedDevice>> trustedDevices() async => devices;

  @override
  Future<void> removeTrustedDevices(
    List<TrustedDevice> removing, {
    required int total,
  }) async {
    removedDevices.add(removing);
    final keys = removing.map((d) => d.hwidKey).toSet();
    devices = [
      for (final device in devices)
        if (!keys.contains(device.hwidKey)) device
    ];
    notifyListeners();
  }

  // ---------------------------------------------------------------- printer

  bool printerSettingHidden = false;
  bool remotePrinterEnabled = true;
  OutgoingPrinterState printerState = OutgoingPrinterState.ready;
  String printerInstall = '';
  var printerInstalls = 0;

  IncomingJobAction jobAction = IncomingJobAction.useDefault;
  List<String> printerNames = const ['Office laser', 'Front desk'];
  String selectedPrinter = '';
  bool autoPrint = false;

  @override
  bool get isPrinterSettingHidden => printerSettingHidden;

  @override
  bool get isRemotePrinterEnabled => remotePrinterEnabled;

  @override
  Future<void> setRemotePrinterEnabled(bool enabled) async {
    remotePrinterEnabled = enabled;
    notifyListeners();
  }

  @override
  OutgoingPrinterState get outgoingPrinterState => printerState;

  @override
  String get printerInstallError => printerInstall;

  @override
  String get appName => 'RustDesk';

  @override
  Future<void> installPrinter() async {
    printerInstalls++;
    notifyListeners();
  }

  @override
  Future<PrinterOptions> printerOptions() async => PrinterOptions(
        action: jobAction,
        printerNames: printerNames,
        printerName: selectedPrinter,
        autoPrint: autoPrint,
      );

  @override
  Future<void> setIncomingJobAction(IncomingJobAction action) async {
    jobAction = action;
    notifyListeners();
  }

  @override
  Future<void> setSelectedPrinter(String name) async {
    selectedPrinter = name;
    notifyListeners();
  }

  @override
  Future<void> setPrinterAutoPrint(bool enabled) async {
    autoPrint = enabled;
    notifyListeners();
  }

  // ---------------------------------------------------------------- plugins

  bool pluginFeatureEnabled = true;
  bool pluginsLoaded = true;
  String pluginFailure = '';
  List<PluginInfo> pluginList = const [];
  final Set<String> enabledPlugins = {};

  /// Plugin ids installed and uninstalled, in order.
  final List<String> installedPlugins = [];
  final List<String> uninstalledPlugins = [];

  var pluginLoads = 0;

  @override
  bool get isPluginFeatureEnabled => pluginFeatureEnabled;

  @override
  bool get arePluginsLoaded => pluginsLoaded;

  @override
  String get pluginFailedReason => pluginFailure;

  @override
  List<PluginInfo> get plugins => pluginList;

  @override
  Future<void> loadPlugins() async => pluginLoads++;

  @override
  bool isPluginEnabled(String id) => enabledPlugins.contains(id);

  @override
  Future<void> installPlugin(PluginInfo plugin) async {
    installedPlugins.add(plugin.meta.id);
    pluginList = [
      for (final p in pluginList)
        if (p.meta.id == plugin.meta.id)
          p.copyWith(installedVersion: p.meta.version)
        else
          p
    ];
    notifyListeners();
  }

  @override
  Future<void> uninstallPlugin(PluginInfo plugin) async {
    uninstalledPlugins.add(plugin.meta.id);
    pluginList = [
      for (final p in pluginList)
        if (p.meta.id == plugin.meta.id) p.copyWith(installedVersion: '') else p
    ];
    notifyListeners();
  }

  @override
  void setPluginEnabled(PluginInfo plugin, bool enabled) {
    if (enabled) {
      enabledPlugins.add(plugin.meta.id);
    } else {
      enabledPlugins.remove(plugin.meta.id);
    }
    notifyListeners();
  }

  @override
  Listenable get pluginChanges => this;

  @override
  Future<String> version() async => '1.4.9';

  @override
  Future<String> fingerprint() async => 'ab:cd:ef';

  @override
  Future<String> license() async => 'AGPL-3.0';
}
