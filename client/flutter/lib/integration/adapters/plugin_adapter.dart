import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// Where a plugin came from.
@immutable
class PluginSource {
  const PluginSource({
    required this.name,
    this.url = '',
    this.description = '',
  });

  /// e.g. 'RustDesk github' or 'Local'.
  final String name;
  final String url;
  final String description;
}

@immutable
class PluginPublishInfo {
  const PluginPublishInfo({
    required this.lastReleased,
    required this.published,
  });

  final DateTime lastReleased;
  final DateTime published;
}

@immutable
class PluginMeta {
  const PluginMeta({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.home,
    required this.license,
    required this.publishInfo,
    required this.source,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String home;
  final String license;
  final PluginPublishInfo publishInfo;
  final String source;
}

/// A plugin as reported by the core's plugin manager.
@immutable
class PluginInfo {
  const PluginInfo({
    required this.source,
    required this.meta,
    required this.installedVersion,
    required this.invalidReason,
    this.failedMsg = '',
  });

  final PluginSource source;
  final PluginMeta meta;

  /// Empty when the plugin is not installed.
  final String installedVersion;

  /// Empty when the plugin is valid.
  final String invalidReason;

  final String failedMsg;

  bool get isInstalled => installedVersion.isNotEmpty;

  bool get isValid => invalidReason.isEmpty;

  bool get needsUpdate => isInstalled && installedVersion != meta.version;

  PluginInfo copyWith({String? installedVersion, String? failedMsg}) =>
      PluginInfo(
        source: source,
        meta: meta,
        installedVersion: installedVersion ?? this.installedVersion,
        invalidReason: invalidReason,
        failedMsg: failedMsg ?? this.failedMsg,
      );
}

/// The plugin list, and the install/enable actions over it.
///
/// The core pushes the list and every install or uninstall result on the same
/// `plugin_manager` global event, so a mutation is requested here and its
/// outcome arrives asynchronously through [plugins].
class PluginAdapter extends ChangeNotifier {
  PluginAdapter();

  static final PluginAdapter instance = PluginAdapter();

  static const String _event = 'plugin_manager';
  static const String _handlerName = 'aurora plugin manager';

  List<PluginInfo> _plugins = const [];
  bool _isLoaded = false;
  String _failedReason = '';
  bool _registered = false;
  bool _disposed = false;

  List<PluginInfo> get plugins => List.unmodifiable(_plugins);

  bool get isLoaded => _isLoaded;

  /// Why the core failed to load plugins, if it did.
  String get failedReason => _failedReason;

  bool get hasError => _failedReason.isNotEmpty;

  /// Whether the build supports plugins at all.
  bool get isFeatureEnabled => bind.pluginFeatureIsEnabled();

  PluginInfo? byId(String id) {
    for (final plugin in _plugins) {
      if (plugin.meta.id == id) return plugin;
    }
    return null;
  }

  /// Subscribe to plugin events and ask the core for the current list.
  Future<void> load() async {
    if (!isFeatureEnabled) {
      _plugins = const [];
      _isLoaded = true;
      notifyListeners();
      return;
    }
    if (!_registered) {
      platformFFI.registerEventHandler(
        _event,
        _handlerName,
        (evt) async => _handleEvent(evt),
        replace: true,
      );
      _registered = true;
    }
    await bind.pluginSyncUi(syncTo: kAppTypeMain);
    await bind.pluginListReload();
  }

  /// Feed the adapter a `plugin_manager` event, as the core would.
  @visibleForTesting
  void handleEvent(Map<String, dynamic> evt) => _handleEvent(evt);

  void _handleEvent(Map<String, dynamic> evt) {
    final list = evt['plugin_list'];
    if (list is String) {
      _handleList(list);
      return;
    }
    final id = evt['id'];
    final install = evt['plugin_install'];
    if (id is String && install is String) {
      _handleInstallResult(id, install, installing: true);
      return;
    }
    final uninstall = evt['plugin_uninstall'];
    if (id is String && uninstall is String) {
      _handleInstallResult(id, uninstall, installing: false);
      return;
    }
    debugPrint('ignoring plugin event: ${evt.keys.toList()}');
  }

  /// Apply the core's answer to an install or uninstall.
  ///
  /// The core reports progress as a message: `finished` or an empty message
  /// means it worked, anything else is the failure to show. Only then does the
  /// installed version change, so a failed install does not read as installed.
  void _handleInstallResult(String id, String message,
      {required bool installing}) {
    final normalised = message == 'finished' ? '' : message;
    final succeeded = normalised.isEmpty;
    _plugins = [
      for (final plugin in _plugins)
        if (plugin.meta.id != id)
          plugin
        else
          plugin.copyWith(
            failedMsg: normalised,
            installedVersion: succeeded
                ? (installing ? plugin.meta.version : '')
                : plugin.installedVersion,
          )
    ];
    _sort();
    if (!_disposed) notifyListeners();
  }

  void _sort() {
    // Installed plugins first, matching the legacy ordering.
    _plugins = [..._plugins]..sort((a, b) {
        if (a.isInstalled == b.isInstalled) return 0;
        return a.isInstalled ? -1 : 1;
      });
  }

  void _handleList(String raw) {
    final next = <PluginInfo>[];
    try {
      for (final entry in json.decode(raw) as List<dynamic>) {
        if (entry is! Map<String, dynamic>) continue;
        final plugin = _parse(entry);
        if (plugin != null) next.add(plugin);
      }
      _failedReason = '';
    } catch (e) {
      debugPrint('failed to decode the plugin list: $e');
      _failedReason = e.toString();
    }
    _plugins = next;
    _sort();
    _isLoaded = true;
    if (!_disposed) notifyListeners();
  }

  PluginInfo? _parse(Map<String, dynamic> evt) {
    final s = evt['source'];
    final m = evt['meta'];
    if (s is! Map || m is! Map) {
      debugPrint('plugin entry without a source or meta: ${evt['id']}');
      return null;
    }
    final id = m['id'];
    if (id is! String || id.isEmpty) return null;

    final publishInfo = m['publish_info'];
    return PluginInfo(
      source: PluginSource(
        name: s['name']?.toString() ?? '',
        url: s['url']?.toString() ?? '',
        description: s['description']?.toString() ?? '',
      ),
      meta: PluginMeta(
        id: id,
        name: m['name']?.toString() ?? '',
        version: m['version']?.toString() ?? '',
        description: m['description']?.toString() ?? '',
        author: m['author']?.toString() ?? '',
        home: m['home']?.toString() ?? '',
        license: m['license']?.toString() ?? '',
        publishInfo: PluginPublishInfo(
          lastReleased: _parseDate(
              publishInfo is Map ? publishInfo['last_released'] : null),
          published:
              _parseDate(publishInfo is Map ? publishInfo['published'] : null),
        ),
        source: m['source']?.toString() ?? '',
      ),
      installedVersion: evt['installed_version']?.toString() ?? '',
      invalidReason: evt['invalid_reason']?.toString() ?? '',
    );
  }

  DateTime _parseDate(dynamic raw) {
    if (raw is! String || raw.isEmpty) return DateTime.utc(1970);
    return DateTime.tryParse(raw) ?? DateTime.utc(1970);
  }

  // ------------------------------------------------------------- mutation

  /// Whether [id] is switched on. An uninstalled plugin is never enabled.
  bool isEnabled(String id) {
    try {
      return bind.pluginIsEnabled(id: id);
    } catch (e) {
      debugPrint('failed to read the plugin state for $id: $e');
      return false;
    }
  }

  /// Install or update [plugin].
  ///
  /// The core works asynchronously and reports the outcome on the same event
  /// the list arrives on, so this returns as soon as the request is accepted
  /// and the result shows up through [plugins].
  Future<void> install(PluginInfo plugin) => _setInstalled(plugin, true);

  Future<void> uninstall(PluginInfo plugin) => _setInstalled(plugin, false);

  Future<void> _setInstalled(PluginInfo plugin, bool installed) async {
    try {
      await bind.pluginInstall(id: plugin.meta.id, b: installed);
    } catch (e) {
      debugPrint('failed to change the install state of ${plugin.meta.id}: $e');
      _handleInstallResult(plugin.meta.id, e.toString(),
          installing: installed);
    }
  }

  /// Switch [plugin] on or off without uninstalling it.
  void setEnabled(PluginInfo plugin, bool enabled) {
    try {
      bind.pluginEnable(id: plugin.meta.id, v: enabled);
      notifyListeners();
    } catch (e) {
      debugPrint('failed to enable ${plugin.meta.id}: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_registered) {
      platformFFI.unregisterEventHandler(_event, _handlerName);
    }
    super.dispose();
  }
}
