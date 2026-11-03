import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/adapters/plugin_adapter.dart';

void main() {
  Map<String, dynamic> entry({
    required String id,
    String version = '1.2.0',
    String installedVersion = '',
    String invalidReason = '',
  }) =>
      {
        'source': {'name': 'RustDesk github'},
        'meta': {
          'id': id,
          'name': id,
          'version': version,
          'publish_info': {
            'last_released': '2026-01-01T00:00:00Z',
            'published': '2026-01-01T00:00:00Z',
          },
        },
        'installed_version': installedVersion,
        'invalid_reason': invalidReason,
      };

  void feedList(PluginAdapter adapter, List<Map<String, dynamic>> entries) =>
      adapter.handleEvent({'plugin_list': jsonEncode(entries)});

  group('plugin list', () {
    test('installed plugins come first', () {
      final adapter = PluginAdapter();
      feedList(adapter, [
        entry(id: 'not-installed'),
        entry(id: 'installed', installedVersion: '1.2.0'),
      ]);

      expect(adapter.plugins.first.meta.id, 'installed');
      expect(adapter.isLoaded, isTrue);
    });

    test('a malformed list is reported, not swallowed', () {
      final adapter = PluginAdapter();
      adapter.handleEvent({'plugin_list': 'not json'});

      expect(adapter.hasError, isTrue);
      expect(adapter.plugins, isEmpty);
    });

    test('an entry without meta is skipped, keeping the rest', () {
      final adapter = PluginAdapter();
      adapter.handleEvent({
        'plugin_list': jsonEncode([
          {'source': {}, 'installed_version': ''},
          entry(id: 'good'),
        ])
      });

      expect(adapter.plugins.map((p) => p.meta.id), ['good']);
      expect(adapter.hasError, isFalse);
    });
  });

  group('install results', () {
    test('a finished install marks the plugin installed', () {
      final adapter = PluginAdapter();
      feedList(adapter, [entry(id: 'demo', version: '1.2.0')]);

      adapter.handleEvent({'id': 'demo', 'plugin_install': 'finished'});

      final plugin = adapter.byId('demo')!;
      expect(plugin.isInstalled, isTrue);
      expect(plugin.installedVersion, '1.2.0');
      expect(plugin.failedMsg, isEmpty);
    });

    test('a failed install is not reported as installed', () {
      final adapter = PluginAdapter();
      feedList(adapter, [entry(id: 'demo')]);

      adapter.handleEvent({'id': 'demo', 'plugin_install': 'Network error'});

      final plugin = adapter.byId('demo')!;
      expect(plugin.isInstalled, isFalse);
      expect(plugin.failedMsg, 'Network error');
    });

    test('a finished uninstall clears the installed version', () {
      final adapter = PluginAdapter();
      feedList(adapter, [entry(id: 'demo', installedVersion: '1.2.0')]);

      adapter.handleEvent({'id': 'demo', 'plugin_uninstall': ''});

      expect(adapter.byId('demo')!.isInstalled, isFalse);
    });

    test('a failed uninstall leaves the plugin installed', () {
      final adapter = PluginAdapter();
      feedList(adapter, [entry(id: 'demo', installedVersion: '1.2.0')]);

      adapter.handleEvent({'id': 'demo', 'plugin_uninstall': 'In use'});

      final plugin = adapter.byId('demo')!;
      expect(plugin.isInstalled, isTrue);
      expect(plugin.failedMsg, 'In use');
    });

    test('a result for an unknown plugin changes nothing', () {
      final adapter = PluginAdapter();
      feedList(adapter, [entry(id: 'demo')]);

      adapter.handleEvent({'id': 'other', 'plugin_install': 'finished'});

      expect(adapter.byId('demo')!.isInstalled, isFalse);
    });
  });

  group('PluginInfo', () {
    test('needs an update when the installed version lags the source', () {
      final adapter = PluginAdapter();
      feedList(adapter,
          [entry(id: 'demo', version: '1.3.0', installedVersion: '1.2.0')]);

      expect(adapter.byId('demo')!.needsUpdate, isTrue);
    });

    test('an up-to-date plugin needs no update', () {
      final adapter = PluginAdapter();
      feedList(adapter,
          [entry(id: 'demo', version: '1.2.0', installedVersion: '1.2.0')]);

      expect(adapter.byId('demo')!.needsUpdate, isFalse);
    });

    test('an invalid plugin says why', () {
      final adapter = PluginAdapter();
      feedList(adapter, [entry(id: 'demo', invalidReason: 'Bad signature')]);

      final plugin = adapter.byId('demo')!;
      expect(plugin.isValid, isFalse);
      expect(plugin.invalidReason, 'Bad signature');
    });
  });
}
