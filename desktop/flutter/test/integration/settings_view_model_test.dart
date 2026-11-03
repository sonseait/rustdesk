import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/features/workspace/settings_view_model.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';

void main() {
  group('option keys', () {
    // Every switch must point at the key the core already persists. A renamed
    // key silently drops the user's existing setting.
    test('security switches use the permission keys', () {
      final keys =
          SettingsViewModel.securityToggles.map((t) => t.key).toList();

      expect(keys, contains('enable-keyboard'));
      expect(keys, contains('enable-clipboard'));
      expect(keys, contains('enable-file-transfer'));
      expect(keys, contains('enable-audio'));
      expect(keys, contains('enable-terminal'));
      expect(keys, contains('enable-remote-restart'));
      expect(keys, contains('enable-block-input'));
    });

    test('network switches use the network keys', () {
      final keys = SettingsViewModel.networkToggles.map((t) => t.key).toList();

      expect(keys, contains('enable-lan-discovery'));
      expect(keys, contains('direct-server'));
      expect(keys, contains('force-always-relay'));
      expect(keys, contains('allow-websocket'));
      expect(keys, contains('enable-udp-punch'));
    });

    test('display switches use the display keys', () {
      final keys = SettingsViewModel.displayToggles.map((t) => t.key).toList();

      expect(keys, contains('show_remote_cursor'));
      expect(keys, contains('show_quality_monitor'));
      expect(keys, contains('enable-abr'));
      expect(keys, contains('enable-hwcodec'));
    });

    test('no key is used twice across the pages', () {
      final all = [
        ...SettingsViewModel.securityToggles,
        ...SettingsViewModel.networkToggles,
        ...SettingsViewModel.workspaceToggles,
        ...SettingsViewModel.displayToggles,
      ].map((t) => t.key).toList();

      expect(all.toSet().length, all.length,
          reason: 'two switches writing one key would fight each other');
    });

    test('every switch has a label and a description', () {
      final all = [
        ...SettingsViewModel.securityToggles,
        ...SettingsViewModel.networkToggles,
        ...SettingsViewModel.workspaceToggles,
        ...SettingsViewModel.displayToggles,
      ];

      for (final toggle in all) {
        expect(toggle.label, isNotEmpty, reason: toggle.key);
        expect(toggle.description, isNotEmpty, reason: toggle.key);
      }
    });
  });

  group('scope', () {
    test('workspace preferences are per install, not synced', () {
      // These describe this machine's UI, so they belong in the local store.
      for (final toggle in SettingsViewModel.workspaceToggles) {
        expect(toggle.scope, SettingScope.local, reason: toggle.key);
      }
    });

    test('permissions are synced config', () {
      for (final toggle in SettingsViewModel.securityToggles) {
        expect(toggle.scope, SettingScope.config, reason: toggle.key);
      }
    });
  });

  group('platform availability', () {
    test('DirectX capture is Windows only', () {
      final directx = SettingsViewModel.displayToggles
          .firstWhere((t) => t.key == kOptionDirectxCapture);

      expect(directx.supportedOn, isNotNull);
      // The suite runs on macOS, where this option does nothing.
      expect(directx.isSupported, isFalse);
    });

    test('wallpaper removal is Windows and Linux only', () {
      final wallpaper = SettingsViewModel.displayToggles
          .firstWhere((t) => t.key == kOptionAllowRemoveWallpaper);

      expect(wallpaper.isSupported, isFalse);
    });

    test('a switch with no platform constraint is always available', () {
      final audio = SettingsViewModel.securityToggles
          .firstWhere((t) => t.key == kOptionEnableAudio);

      expect(audio.supportedOn, isNull);
      expect(audio.isSupported, isTrue);
    });
  });

  group('ToggleState', () {
    test('is editable only without a lock', () {
      const toggle = SettingToggle(
          key: 'k', label: 'l', description: 'd');

      expect(
        const ToggleState(
                toggle: toggle, value: true, lock: OptionLock.none)
            .isEditable,
        isTrue,
      );
      for (final lock in [
        OptionLock.fixed,
        OptionLock.managed,
        OptionLock.unsupported,
      ]) {
        final state =
            ToggleState(toggle: toggle, value: true, lock: lock);
        expect(state.isEditable, isFalse, reason: '$lock');
        // A locked switch has to say why, not just refuse.
        expect(state.lockReason, isNotNull, reason: '$lock');
      }
    });

    test('an editable switch has no reason to show', () {
      const toggle = SettingToggle(key: 'k', label: 'l', description: 'd');
      const state =
          ToggleState(toggle: toggle, value: false, lock: OptionLock.none);

      expect(state.lockReason, isNull);
    });
  });

  group('ServerConfig', () {
    test('reports empty when nothing is configured', () {
      expect(const ServerConfig().isEmpty, isTrue);
      expect(const ServerConfig(idServer: 'a').isEmpty, isFalse);
    });

    test('copyWith replaces one field', () {
      const config = ServerConfig(idServer: 'a', relayServer: 'b');
      final updated = config.copyWith(relayServer: 'c');

      expect(updated.idServer, 'a');
      expect(updated.relayServer, 'c');
    });
  });

  group('ProxyConfig', () {
    test('is set only once an address is present', () {
      expect(const ProxyConfig().isSet, isFalse);
      expect(const ProxyConfig(username: 'agent').isSet, isFalse);
      expect(const ProxyConfig(address: 'socks5://host:1080').isSet, isTrue);
    });

    test('copyWith replaces one field', () {
      const config = ProxyConfig(address: 'a', username: 'b');
      final updated = config.copyWith(username: 'c');

      expect(updated.address, 'a');
      expect(updated.username, 'c');
    });
  });

  group('proxy option key', () {
    test('the lock key is the name the legacy dialog used', () {
      // `proxy-url` is not stored; a custom client pins that name to lock the
      // proxy, so renaming it would silently unlock a managed deployment.
      expect(kOptionProxyUrl, 'proxy-url');
    });

    test('the hide key is the name the core reads', () {
      expect(kOptionHideProxySetting, 'hide-proxy-settings');
    });
  });

  group('SettingsTab', () {
    test('matches the legacy deep-link names', () {
      // These are the existing SettingsTabKey values; a rename breaks any
      // saved link that opens a settings page.
      expect(SettingsTab.values.map((t) => t.name).toList(), [
        'general',
        'safety',
        'network',
        'display',
        'plugin',
        'account',
        'printer',
        'about',
      ]);
    });
  });
}
