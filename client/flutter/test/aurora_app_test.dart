import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/features/workspace/settings_view_model.dart';
import 'package:flutter_hbb/features/workspace/workspace_page.dart';
import 'package:flutter_hbb/features/workspace/workspace_view_model.dart';
import 'package:flutter_hbb/integration/adapters/connect_adapter.dart';
import 'package:flutter_hbb/integration/adapters/peer.dart';
import 'package:flutter_hbb/integration/adapters/plugin_adapter.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';

import 'support/fake_settings_view_model.dart';
import 'support/fake_workspace_view_model.dart';

/// Pump the workspace with an injected model.
///
/// The real model needs the native bridge, which widget tests do not have, so
/// every test drives the surfaces through [FakeWorkspaceViewModel].
Future<FakeWorkspaceViewModel> pumpWorkspace(
  WidgetTester tester, {
  FakeWorkspaceViewModel? model,
  FakeSettingsViewModel? settings,
  Size size = const Size(1200, 900),
}) async {
  final viewModel = model ?? FakeWorkspaceViewModel();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(CupertinoApp(
    home: WorkspacePage(
      brightness: Brightness.light,
      onBrightnessChanged: (_) {},
      viewModel: viewModel,
      settings: settings ?? FakeSettingsViewModel(),
    ),
  ));
  await tester.pumpAndSettle();
  return viewModel;
}

/// Publish dates a plugin fixture needs but no assertion looks at.
final _epochPublishInfo = PluginPublishInfo(
  lastReleased: DateTime.utc(1970),
  published: DateTime.utc(1970),
);

void main() {
  group('overview', () {
    testWidgets('shows the real device id, formatted', (tester) async {
      await pumpWorkspace(tester);

      expect(find.text('847 293 160'), findsOneWidget);
      expect(find.text('Connect in a moment'), findsOneWidget);
    });

    testWidgets('shows a generating state before the id exists',
        (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
            identityOverride: const IdentityView(
              deviceId: '',
              isLoading: true,
              isOnline: false,
              isServiceRunning: false,
              temporaryPassword: '',
            ),
          ));

      expect(find.text('Generating…'), findsOneWidget);
      // No fake id is shown while the core is still starting.
      expect(find.text('847 293 160'), findsNothing);
    });

    testWidgets('reports offline rather than always claiming online',
        (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
            identityOverride: const IdentityView(
              deviceId: '847293160',
              isLoading: false,
              isOnline: false,
              isServiceRunning: true,
              temporaryPassword: '',
            ),
          ));

      expect(find.text('Offline'), findsWidgets);
      expect(
          find.text('Offline — not registered with the server'), findsOneWidget);
    });

    testWidgets('says when sharing is stopped', (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
            identityOverride: const IdentityView(
              deviceId: '847293160',
              isLoading: false,
              isOnline: true,
              isServiceRunning: false,
              temporaryPassword: '',
            ),
          ));

      expect(find.textContaining('Sharing is stopped'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('renders an error panel when the bridge is unavailable',
        (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(bridgeReady: false));

      expect(find.text('RustDesk core unavailable'), findsOneWidget);
      // It must not look like a healthy, empty workspace.
      expect(find.text('Connect in a moment'), findsNothing);
    });

    testWidgets('pulse counts come from the peer lists', (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
            recent: [
              testPeer('111', online: true),
              testPeer('222'),
            ],
            favorites: [testPeer('111', online: true)],
          ));

      expect(find.text('Known devices'), findsOneWidget);
      // Two distinct peers, one online, one favorite.
      expect(find.text('2'), findsWidgets);
      expect(find.text('1'), findsWidgets);
    });
  });

  group('devices', () {
    Future<FakeWorkspaceViewModel> pumpDevices(
      WidgetTester tester, {
      FakeWorkspaceViewModel? model,
    }) async {
      final viewModel = await pumpWorkspace(tester, model: model);
      await tester.tap(find.text('Devices'));
      await tester.pumpAndSettle();
      return viewModel;
    }

    testWidgets('lists real peers by alias and platform', (tester) async {
      await pumpDevices(tester,
          model: FakeWorkspaceViewModel(recent: [
            testPeer('847293160',
                alias: 'Studio Mac',
                platform: PeerPlatform.macOS,
                online: true),
            testPeer('982671046',
                alias: 'Pixel 9', platform: PeerPlatform.android),
          ]));

      expect(find.text('Studio Mac'), findsOneWidget);
      expect(find.text('Pixel 9'), findsOneWidget);
      expect(find.text('Mac OS · Online'), findsOneWidget);
    });

    testWidgets('shows the formatted id when a peer has no alias',
        (tester) async {
      await pumpDevices(tester,
          model: FakeWorkspaceViewModel(recent: [testPeer('847293160')]));

      expect(find.text('847 293 160'), findsWidgets);
    });

    testWidgets('filters devices from the search field', (tester) async {
      await pumpDevices(tester,
          model: FakeWorkspaceViewModel(recent: [
            testPeer('1', alias: 'Studio Mac'),
            testPeer('2', alias: 'Pixel 9'),
          ]));

      await tester.enterText(find.byType(CupertinoTextField).first, 'Pixel');
      await tester.pumpAndSettle();

      expect(find.text('Pixel 9'), findsOneWidget);
      expect(find.text('Studio Mac'), findsNothing);
    });

    testWidgets('distinguishes loading from empty', (tester) async {
      await pumpDevices(tester,
          model: FakeWorkspaceViewModel(stateOverride: LoadState.loading));

      expect(find.text('Loading devices…'), findsOneWidget);
      expect(find.text('No devices yet'), findsNothing);
    });

    testWidgets('shows an empty state when there are genuinely no peers',
        (tester) async {
      await pumpDevices(tester);

      expect(find.text('No devices yet'), findsOneWidget);
    });

    testWidgets('surfaces a load error instead of an empty list',
        (tester) async {
      await pumpDevices(tester,
          model: FakeWorkspaceViewModel(stateOverride: LoadState.error));

      expect(find.text('Could not load devices'), findsOneWidget);
      expect(find.text('device list unavailable'), findsOneWidget);
    });

    testWidgets('explains that a filter is hiding results', (tester) async {
      await pumpDevices(tester,
          model: FakeWorkspaceViewModel(recent: [testPeer('1')]));

      await tester.enterText(
          find.byType(CupertinoTextField).first, 'no-such-device');
      await tester.pumpAndSettle();

      expect(find.text('No matching devices'), findsOneWidget);
    });

    testWidgets('tapping a device connects through the model', (tester) async {
      final model = await pumpDevices(tester,
          model: FakeWorkspaceViewModel(
              recent: [testPeer('847293160', alias: 'Studio Mac')]));

      await tester.tap(find.text('Studio Mac'));
      await tester.pumpAndSettle();

      expect(model.connectCalls, [('847293160', ConnectionKind.remoteDesktop)]);
    });

    testWidgets('the online filter hides offline peers', (tester) async {
      await pumpDevices(tester,
          model: FakeWorkspaceViewModel(recent: [
            testPeer('1', alias: 'Up', online: true),
            testPeer('2', alias: 'Down'),
          ]));

      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();

      expect(find.text('Up'), findsOneWidget);
      expect(find.text('Down'), findsNothing);
    });
  });

  group('peer actions', () {
    Future<FakeWorkspaceViewModel> openDeviceMenu(WidgetTester tester) async {
      final model = await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
              recent: [testPeer('847293160', alias: 'Studio Mac')]));
      await tester.tap(find.text('Devices'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('the dropdown invokes model actions', (tester) async {
      final model = await openDeviceMenu(tester);

      await tester.tap(find.text('Add to favorites'));
      await tester.pumpAndSettle();

      expect(model.favoriteToggles, ['847293160']);
    });

    testWidgets('the menu offers every peer action', (tester) async {
      await openDeviceMenu(tester);

      expect(find.text('Connect'), findsWidgets);
      expect(find.text('Add to favorites'), findsOneWidget);
      // This peer already has an alias, so the action reads Rename.
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Forget password'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      // It is a dropdown, not a bottom sheet, so there is no Cancel row.
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('selecting an action closes the menu', (tester) async {
      await openDeviceMenu(tester);
      expect(find.text('Remove'), findsOneWidget);

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('tapping outside dismisses the menu without acting',
        (tester) async {
      final model = await openDeviceMenu(tester);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('Add to favorites'), findsNothing);
      expect(model.favoriteToggles, isEmpty);
      expect(model.removals, isEmpty);
    });

    testWidgets('the menu opens at the pointer, not the row edge',
        (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
              recent: [testPeer('847293160', alias: 'Studio Mac')]));
      await tester.tap(find.text('Devices'));
      await tester.pumpAndSettle();

      final trigger =
          tester.getCenter(find.byIcon(LucideIcons.ellipsisVertical));
      await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
      await tester.pumpAndSettle();

      // The menu's top-left should sit at the click point, not float away
      // from it the way a box-anchored follower did.
      final menuTopLeft = tester.getTopLeft(find.text('Connect').last);
      expect((menuTopLeft.dy - trigger.dy).abs(), lessThan(30),
          reason: 'menu should open next to the pointer vertically');
      expect((menuTopLeft.dx - trigger.dx).abs(), lessThan(200),
          reason: 'menu should open next to the pointer horizontally');
    });

    testWidgets('the menu stays on screen near the right edge',
        (tester) async {
      // A narrow window puts the trigger close to the right edge, where an
      // unclamped menu would overflow.
      await pumpWorkspace(tester,
          size: const Size(560, 900),
          model: FakeWorkspaceViewModel(
              recent: [testPeer('847293160', alias: 'Studio Mac')]));
      await tester.tap(find.text('Devices'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.ellipsisVertical).first);
      await tester.pumpAndSettle();

      final menu = tester.getRect(find.text('Forget password'));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(560));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the label reflects current favorite state', (tester) async {
      final model = FakeWorkspaceViewModel(
          recent: [testPeer('847293160', alias: 'Studio Mac')]);
      model.markFavorite('847293160');

      await pumpWorkspace(tester, model: model);
      await tester.tap(find.text('Devices'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
      await tester.pumpAndSettle();

      expect(find.text('Remove from favorites'), findsOneWidget);
      expect(find.text('Add to favorites'), findsNothing);
    });
  });

  group('quick connect', () {
    testWidgets('connects with the typed id', (tester) async {
      final model = await pumpWorkspace(tester);

      await tester.enterText(find.byType(CupertinoTextField).first, '111222');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(model.connectCalls, [('111222', ConnectionKind.remoteDesktop)]);
    });

    testWidgets('an empty field does not connect to a made-up device',
        (tester) async {
      final model = await pumpWorkspace(tester);

      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(model.connectCalls, isEmpty);
    });

    testWidgets('the mode picker selects the connection kind', (tester) async {
      final model = await pumpWorkspace(tester);

      await tester.enterText(find.byType(CupertinoTextField).first, '111222');
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(model.connectCalls, [('111222', ConnectionKind.fileTransfer)]);
    });

    testWidgets('a failed connection is reported', (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
            connectResult: const ConnectResult.failure(
                '111222', ConnectFailure.failed,
                error: 'refused'),
          ));

      await tester.enterText(find.byType(CupertinoTextField).first, '111222');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(find.text('Could not connect'), findsOneWidget);
      expect(find.textContaining('refused'), findsOneWidget);
    });
  });

  group('command palette', () {
    testWidgets('matches known peers by name', (tester) async {
      final model = await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
              recent: [testPeer('847293160', alias: 'Studio Mac')]));

      await tester.tap(find.byIcon(LucideIcons.search).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).last, 'Studio');
      await tester.pumpAndSettle();

      // The device card behind the dialog also carries the name, so target
      // the palette's combined "alias · id" row.
      await tester.tap(find.text('Studio Mac · 847 293 160'));
      await tester.pumpAndSettle();

      expect(model.connectCalls, [('847293160', ConnectionKind.remoteDesktop)]);
    });

    testWidgets('an empty palette entry does not connect', (tester) async {
      final model = await pumpWorkspace(tester);

      await tester.tap(find.byIcon(LucideIcons.search).first);
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(model.connectCalls, isEmpty);
    });
  });

  group('notifications', () {
    testWidgets('reports a healthy workspace when nothing is wrong',
        (tester) async {
      await pumpWorkspace(tester);

      await tester.tap(find.byIcon(LucideIcons.bell));
      await tester.pumpAndSettle();

      expect(find.text('Your workspace is healthy'), findsOneWidget);
    });

    testWidgets('reports a stopped service instead of all-clear',
        (tester) async {
      await pumpWorkspace(tester,
          model: FakeWorkspaceViewModel(
            identityOverride: const IdentityView(
              deviceId: '847293160',
              isLoading: false,
              isOnline: true,
              isServiceRunning: false,
              temporaryPassword: '',
            ),
          ));

      await tester.tap(find.byIcon(LucideIcons.bell));
      await tester.pumpAndSettle();

      expect(find.text('Sharing is stopped'), findsOneWidget);
      expect(find.text('Your workspace is healthy'), findsNothing);
    });
  });

  group('settings', () {
    testWidgets('changes the application appearance', (tester) async {
      final model = FakeWorkspaceViewModel();
      var brightness = Brightness.light;

      // Tall enough that the appearance control is laid out without needing
      // to scroll the settings list.
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(StatefulBuilder(
        builder: (context, setState) => CupertinoApp(
          theme: CupertinoThemeData(brightness: brightness),
          home: WorkspacePage(
            brightness: brightness,
            onBrightnessChanged: (value) =>
                setState(() => brightness = value),
            viewModel: model,
            settings: FakeSettingsViewModel(),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('appearance-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(brightness, Brightness.dark);
    });

    testWidgets('opens a dedicated settings subpage', (tester) async {
      await pumpWorkspace(tester);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Access password'));
      await tester.pumpAndSettle();

      expect(find.text('Password protection'), findsOneWidget);
    });
  });

  group('layout', () {
    testWidgets('keeps the mobile workspace compact', (tester) async {
      await pumpWorkspace(tester, size: const Size(390, 844));

      expect(find.text('Connect in a moment'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('settings are backed by real options', () {
    Future<FakeSettingsViewModel> pumpSettings(
      WidgetTester tester, {
      FakeSettingsViewModel? settings,
    }) async {
      final model = settings ?? FakeSettingsViewModel();
      await pumpWorkspace(tester, settings: model, size: const Size(1200, 1800));
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('shows the permission switches from the core', (tester) async {
      await pumpSettings(tester);

      // These are the real permission keys, not invented rows. Their
      // descriptions are unique; the labels also appear as category chips.
      expect(find.text('Keyboard and mouse'), findsOneWidget);
      expect(find.text('Let people who connect control this device.'),
          findsOneWidget);
      expect(find.text('Share clipboard contents with the connected device.'),
          findsOneWidget);
      expect(find.text('Allow files to be sent and received.'), findsOneWidget);
    });

    testWidgets('flipping a switch writes its option key', (tester) async {
      final settings = await pumpSettings(tester);

      final target = find.descendant(
        of: find.byKey(const Key('setting-enable-keyboard')),
        matching: find.byType(CupertinoSwitch),
      );

      await tester.tap(target);
      await tester.pumpAndSettle();

      expect(settings.written, ['enable-keyboard']);
    });

    testWidgets('a pinned option says so and cannot be changed',
        (tester) async {
      final settings = await pumpSettings(
        tester,
        settings: FakeSettingsViewModel(
          locks: {'enable-clipboard': OptionLock.fixed},
        ),
      );

      // The user is told why rather than seeing a switch spring back.
      expect(find.textContaining('Managed by your deployment'), findsWidgets);

      final target = find.descendant(
        of: find.byKey(const Key('setting-enable-clipboard')),
        matching: find.byType(CupertinoSwitch),
      );

      await tester.tap(target, warnIfMissed: false);
      await tester.pumpAndSettle();

      // A locked switch is disabled, so nothing is written.
      expect(settings.written, isEmpty);
    });

    // The server-settings row lives in the Network panel, which a lazy
    // ListView has not built at this scroll position. Its lock state is
    // covered by the SettingsViewModel tests instead of asserted here on a
    // widget that does not exist yet.

    testWidgets('a locked password says so', (tester) async {
      await pumpSettings(tester,
          settings: FakeSettingsViewModel(passwordChangeDisabled: true));

      expect(find.text('Access password'), findsOneWidget);
      expect(find.textContaining('Managed by your deployment'), findsWidgets);
    });

    testWidgets('a build that cannot be controlled has no Access panel',
        (tester) async {
      // Every switch there permits something an incoming connection may do.
      // On a build with no screen to share, showing them would offer settings
      // that govern nothing.
      await pumpSettings(tester,
          settings: FakeSettingsViewModel()..incomingPermissions = false);

      expect(find.text('Access password'), findsNothing);
      expect(find.text('Let people who connect control this device.'),
          findsNothing);
      // The rest of settings is still there.
      expect(find.text('This device'), findsWidgets);
    });
  });

  group('settings subpages', () {
    Future<FakeSettingsViewModel> openSubpage(
      WidgetTester tester,
      String row, {
      FakeSettingsViewModel? settings,
    }) async {
      final model = settings ?? FakeSettingsViewModel();
      await pumpWorkspace(tester,
          settings: model, size: const Size(1200, 1800));
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(row));
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('setting a password sends it to the core', (tester) async {
      final settings = await openSubpage(tester, 'Access password');

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'hunter2hunter2');
      await tester.enterText(fields.at(1), 'hunter2hunter2');
      await tester.tap(find.text('Set password'));
      await tester.pumpAndSettle();

      expect(settings.passwords, ['hunter2hunter2']);
      expect(find.text('Password updated'), findsOneWidget);
    });

    testWidgets('mismatched passwords never reach the core', (tester) async {
      final settings = await openSubpage(tester, 'Access password');

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'one-password');
      await tester.enterText(fields.at(1), 'another-password');
      await tester.tap(find.text('Set password'));
      await tester.pumpAndSettle();

      expect(settings.passwords, isEmpty);
      expect(find.text('The two passwords do not match.'), findsOneWidget);
    });

    testWidgets('a rejected password is reported, not claimed as saved',
        (tester) async {
      final settings = FakeSettingsViewModel()..acceptPassword = false;
      await openSubpage(tester, 'Access password', settings: settings);

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'short');
      await tester.enterText(fields.at(1), 'short');
      await tester.tap(find.text('Set password'));
      await tester.pumpAndSettle();

      expect(find.textContaining('rejected'), findsOneWidget);
      expect(find.text('Password updated'), findsNothing);
    });

    testWidgets('a managed password shows an explanation, not a form',
        (tester) async {
      await openSubpage(tester, 'Access password',
          settings: FakeSettingsViewModel(passwordChangeDisabled: true));

      expect(find.textContaining('deployment manages this password'),
          findsOneWidget);
      expect(find.text('Set password'), findsNothing);
    });

    // The About row sits in the last settings panel, which a lazy ListView
    // has not built at the default scroll position. _AboutPanel reads its
    // three values through SettingsViewModel, which is covered by the model
    // tests; asserting on a widget that does not exist here would prove
    // nothing.
  });

  group('settings deep links', () {
    testWidgets('a safety link opens the access category', (tester) async {
      // The legacy "change this password" link pointed at SettingsTabKey
      // .safety; Aurora keeps those settings under Access.
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: FakeSettingsViewModel(),
          initialSettingsTab: SettingsTab.safety,
        ),
      ));
      await tester.pumpAndSettle();

      // Settings is showing, filtered to the permission switches.
      expect(find.text('Workspace settings'), findsOneWidget);
      expect(find.text('Let people who connect control this device.'),
          findsOneWidget);
    });

    testWidgets('no link opens the workspace as usual', (tester) async {
      await pumpWorkspace(tester);

      expect(find.text('Connect in a moment'), findsOneWidget);
    });

    testWidgets('a network link opens the network category', (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: FakeSettingsViewModel(),
          initialSettingsTab: SettingsTab.network,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Accept connections without going through a relay.'),
          findsOneWidget);
    });
  });

  group('the sharing page', () {
    Future<void> pumpWith(
      WidgetTester tester, {
      required bool showsSharing,
      SettingsTab? initialTab,
      Size size = const Size(420, 1000),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: FakeSettingsViewModel(),
          initialSettingsTab: initialTab,
          showsSharing: showsSharing,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('is offered where this device shares its own screen',
        (tester) async {
      await pumpWith(tester, showsSharing: true);

      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('is absent where sharing runs in the background',
        (tester) async {
      // A desktop runs the service without a page of its own.
      await pumpWith(tester, showsSharing: false);

      expect(find.text('Share'), findsNothing);
    });

    testWidgets('opens the sharing surface', (tester) async {
      await pumpWith(tester, showsSharing: true);

      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      expect(find.text('Share this screen'), findsOneWidget);
    });

    testWidgets('a settings deep link still lands on settings', (tester) async {
      // Sharing sits after settings in the page order precisely so adding it
      // cannot shift where a saved settings link points.
      await pumpWith(tester,
          showsSharing: true,
          initialTab: SettingsTab.network,
          size: const Size(1200, 1800));

      expect(find.text('Accept connections without going through a relay.'),
          findsOneWidget);
    });

    testWidgets('appears in the sidebar on a wide window', (tester) async {
      await pumpWith(tester,
          showsSharing: true, size: const Size(1200, 1000));

      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Overview'), findsOneWidget);
    });
  });

  group('printer settings', () {
    // The printing row sits in the File transfer panel, which the printer
    // deep link filters the list down to.
    Future<FakeSettingsViewModel> openPrinter(
      WidgetTester tester, {
      FakeSettingsViewModel? settings,
    }) async {
      final model = settings ?? FakeSettingsViewModel();
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: model,
          initialSettingsTab: SettingsTab.printer,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Printing'));
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('an OS without driver support offers no install button',
        (tester) async {
      await openPrinter(tester,
          settings: FakeSettingsViewModel()
            ..printerState = OutgoingPrinterState.unsupportedOs);

      expect(find.textContaining('cannot host'), findsOneWidget);
      expect(find.textContaining('Install RustDesk printer'), findsNothing);
    });

    testWidgets('a missing printer can be installed', (tester) async {
      final settings = FakeSettingsViewModel()
        ..printerState = OutgoingPrinterState.printerNotInstalled;
      await openPrinter(tester, settings: settings);

      await tester.tap(find.text('Install RustDesk printer'));
      await tester.pumpAndSettle();

      expect(settings.printerInstalls, 1);
    });

    testWidgets('a failed install is reported, not hidden', (tester) async {
      await openPrinter(tester,
          settings: FakeSettingsViewModel()
            ..printerState = OutgoingPrinterState.printerNotInstalled
            ..printerInstall = 'Driver signature rejected');

      expect(find.text('Driver signature rejected'), findsOneWidget);
    });

    testWidgets('choosing an action writes it through the core',
        (tester) async {
      final settings = await openPrinter(tester);

      await tester.tap(find.text('Dismiss the job'));
      await tester.pumpAndSettle();

      expect(settings.jobAction, IncomingJobAction.dismiss);
    });

    testWidgets('auto-print is locked while jobs are dismissed',
        (tester) async {
      final settings = FakeSettingsViewModel()
        ..jobAction = IncomingJobAction.dismiss;
      await openPrinter(tester, settings: settings);

      // A dismissed job never reaches a printer, so the switch says why
      // instead of pretending to work.
      expect(find.textContaining('Jobs are being dismissed'), findsOneWidget);
    });

    testWidgets('a printer is only chosen for the selected-printer action',
        (tester) async {
      final settings = FakeSettingsViewModel()
        ..jobAction = IncomingJobAction.useSelected
        ..selectedPrinter = 'Front desk';
      await openPrinter(tester, settings: settings);

      expect(find.text('Front desk'), findsOneWidget);
    });

    testWidgets('with no printers the chosen-printer action is unavailable',
        (tester) async {
      final settings = FakeSettingsViewModel()..printerNames = const [];
      await openPrinter(tester, settings: settings);

      await tester.tap(find.text('Use a chosen printer'));
      await tester.pumpAndSettle();

      expect(settings.jobAction, IncomingJobAction.useDefault);
      expect(find.textContaining('No printer is available'), findsOneWidget);
    });

    testWidgets('a hidden printer setting cannot be opened', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: FakeSettingsViewModel()..printerSettingHidden = true,
          initialSettingsTab: SettingsTab.printer,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Printing'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Managed by your deployment'), findsWidgets);
      expect(find.text('Print jobs sent to this device'), findsNothing);
    });
  });

  group('plugin settings', () {
    final demoPlugin = PluginInfo(
      source: const PluginSource(name: 'RustDesk github'),
      meta: PluginMeta(
        id: 'demo',
        name: 'Demo plugin',
        version: '1.3.0',
        description: 'Adds a demo panel',
        author: 'RustDesk',
        home: '',
        license: 'AGPL-3.0',
        publishInfo: _epochPublishInfo,
        source: 'github',
      ),
      installedVersion: '',
      invalidReason: '',
    );

    Future<FakeSettingsViewModel> openPlugins(
      WidgetTester tester, {
      FakeSettingsViewModel? settings,
    }) async {
      final model = settings ?? FakeSettingsViewModel();
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: model,
          initialSettingsTab: SettingsTab.plugin,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins').first);
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('a build without plugin support says so', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: FakeSettingsViewModel()..pluginFeatureEnabled = false,
          initialSettingsTab: SettingsTab.plugin,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins').first);
      await tester.pumpAndSettle();

      // The row is not a link when the build has no plugin support, so the
      // subpage never opens.
      expect(find.text('Not available in this build'), findsOneWidget);
    });

    testWidgets('a list the core could not read is reported', (tester) async {
      await openPlugins(tester,
          settings: FakeSettingsViewModel()
            ..pluginFailure = 'Source unreachable');

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.text('Source unreachable'), findsOneWidget);
    });

    testWidgets('an empty list is stated, not left blank', (tester) async {
      await openPlugins(tester);

      expect(find.textContaining('No plugin is available'), findsOneWidget);
    });

    testWidgets('installing a plugin goes through the core', (tester) async {
      final settings = FakeSettingsViewModel()
        ..pluginList = [demoPlugin];
      await openPlugins(tester, settings: settings);

      expect(find.text('Demo plugin'), findsOneWidget);
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(settings.installedPlugins, ['demo']);
      expect(find.text('Uninstall'), findsOneWidget);
    });

    testWidgets('an installed plugin can be switched off', (tester) async {
      final settings = FakeSettingsViewModel()
        ..pluginList = [demoPlugin.copyWith(installedVersion: '1.3.0')]
        ..enabledPlugins.add('demo');
      await openPlugins(tester, settings: settings);

      await tester.tap(find.byType(CupertinoSwitch).last);
      await tester.pumpAndSettle();

      expect(settings.isPluginEnabled('demo'), isFalse);
    });

    testWidgets('an outdated plugin offers the new version', (tester) async {
      final settings = FakeSettingsViewModel()
        ..pluginList = [demoPlugin.copyWith(installedVersion: '1.2.0')];
      await openPlugins(tester, settings: settings);

      await tester.tap(find.text('Update to 1.3.0'));
      await tester.pumpAndSettle();

      expect(settings.installedPlugins, ['demo']);
    });

    testWidgets('an invalid plugin cannot be installed', (tester) async {
      final settings = FakeSettingsViewModel()
        ..pluginList = [
          PluginInfo(
            source: const PluginSource(name: 'Local'),
            meta: PluginMeta(
              id: 'broken',
              name: 'Broken plugin',
              version: '0.1.0',
              description: '',
              author: '',
              home: '',
              license: '',
              publishInfo: _epochPublishInfo,
              source: 'local',
            ),
            installedVersion: '',
            invalidReason: 'Bad signature',
          )
        ];
      await openPlugins(tester, settings: settings);

      expect(find.text('Bad signature'), findsOneWidget);
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(settings.installedPlugins, isEmpty);
    });
  });

  group('two-factor settings', () {
    // The 2FA row sits in the Access panel. The safety deep link filters the
    // list to that panel, so the row is built rather than left off-screen by
    // the lazy ListView.
    Future<FakeSettingsViewModel> openTwoFactor(
      WidgetTester tester, {
      FakeSettingsViewModel? settings,
    }) async {
      final model = settings ?? FakeSettingsViewModel();
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: model,
          initialSettingsTab: SettingsTab.safety,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Two-factor authentication').first);
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('setup shows the secret and turns 2FA on once verified',
        (tester) async {
      final settings = await openTwoFactor(tester);

      expect(find.text('Off'), findsOneWidget);
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();

      // The typed key is the same enrolment for apps that cannot scan.
      expect(find.text('JBSWY3DPEHPK3PXP'), findsOneWidget);

      await tester.enterText(find.byType(CupertinoTextField).last, '123456');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(settings.codes, ['123456']);
      expect(settings.isTwoFactorEnabled, isTrue);
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('a rejected code leaves 2FA off', (tester) async {
      final settings = FakeSettingsViewModel()..acceptCode = false;
      await openTwoFactor(tester, settings: settings);

      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).last, '000000');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(settings.isTwoFactorEnabled, isFalse);
      expect(find.textContaining('not accepted'), findsOneWidget);
      expect(find.text('On'), findsNothing);
    });

    testWidgets('setup the core cannot start is reported, not faked',
        (tester) async {
      final settings = FakeSettingsViewModel()..enrolmentUri = '';
      await openTwoFactor(tester, settings: settings);

      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not start setup'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
    });

    testWidgets('turning 2FA off drops the trusted devices', (tester) async {
      final settings = FakeSettingsViewModel()
        ..twoFactorEnabled = true
        ..trustedDevicesEnabled = true
        ..devices = const [
          TrustedDevice(
              hwid: [1],
              time: 1700000000000,
              id: '847293160',
              name: 'Ada workstation',
              platform: 'Linux')
        ];
      await openTwoFactor(tester, settings: settings);

      expect(find.text('Ada workstation'), findsOneWidget);
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();

      expect(settings.isTwoFactorEnabled, isFalse);
      expect(settings.devices, isEmpty);
      expect(find.text('Ada workstation'), findsNothing);
    });

    testWidgets('trusted devices are hidden until they are allowed',
        (tester) async {
      final settings = FakeSettingsViewModel()..twoFactorEnabled = true;
      await openTwoFactor(tester, settings: settings);

      expect(find.text('Allow trusted devices'), findsOneWidget);
      expect(find.text('No device has been trusted yet.'), findsNothing);

      await tester.tap(find.byType(CupertinoSwitch).last);
      await tester.pumpAndSettle();

      expect(settings.trustedDevicesEnabled, isTrue);
      expect(find.text('No device has been trusted yet.'), findsOneWidget);
    });

    testWidgets('a selected trusted device is removed through the core',
        (tester) async {
      final settings = FakeSettingsViewModel()
        ..twoFactorEnabled = true
        ..trustedDevicesEnabled = true
        ..devices = const [
          TrustedDevice(
              hwid: [1],
              time: 1700000000000,
              id: '847293160',
              name: 'Ada workstation',
              platform: 'Linux'),
          TrustedDevice(
              hwid: [2],
              time: 1600000000000,
              id: '112233445',
              name: 'Studio Mac',
              platform: 'Mac OS'),
        ];
      await openTwoFactor(tester, settings: settings);

      await tester.tap(find.text('Ada workstation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove selected'));
      await tester.pumpAndSettle();

      expect(settings.removedDevices.single.single.id, '847293160');
      expect(find.text('Ada workstation'), findsNothing);
      expect(find.text('Studio Mac'), findsOneWidget);
    });

    testWidgets('a bot token the core rejects is reported', (tester) async {
      final settings = FakeSettingsViewModel()
        ..twoFactorEnabled = true
        ..botError = 'Invalid token';
      await openTwoFactor(tester, settings: settings);

      await tester.enterText(find.byType(CupertinoTextField).last, 'bad-token');
      await tester.tap(find.text('Add bot'));
      await tester.pumpAndSettle();

      expect(settings.botTokens, ['bad-token']);
      expect(settings.hasTelegramBot, isFalse);
      expect(find.text('Invalid token'), findsOneWidget);
    });
  });

  group('proxy settings', () {
    // The proxy row sits in the Network panel. Opening settings through the
    // network deep link filters the list to that panel, so the row is built
    // rather than left off-screen by the lazy ListView.
    Future<FakeSettingsViewModel> openProxy(
      WidgetTester tester, {
      FakeSettingsViewModel? settings,
    }) async {
      final model = settings ?? FakeSettingsViewModel();
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: model,
          initialSettingsTab: SettingsTab.network,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxy'));
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('the current proxy is read from the core', (tester) async {
      final settings = FakeSettingsViewModel()
        ..proxy = const ProxyConfig(
            address: 'socks5://proxy.example.com:1080',
            username: 'agent',
            password: 'secret')
        ..proxyActive = true;
      await openProxy(tester, settings: settings);

      expect(find.text('socks5://proxy.example.com:1080'), findsOneWidget);
      expect(find.text('agent'), findsOneWidget);
      expect(find.text('In use'), findsOneWidget);
    });

    testWidgets('saving sends the proxy to the core', (tester) async {
      final settings = await openProxy(tester);

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'socks5://proxy.example.com:1080');
      await tester.enterText(fields.at(1), 'agent');
      await tester.enterText(fields.at(2), 'secret');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.savedProxies.single.address,
          'socks5://proxy.example.com:1080');
      expect(settings.savedProxies.single.username, 'agent');
      expect(settings.savedProxies.single.password, 'secret');
      expect(find.text('Proxy saved'), findsOneWidget);
    });

    testWidgets('an address the core rejects is never saved', (tester) async {
      final settings = FakeSettingsViewModel()
        ..proxyValidationError = 'Invalid address';
      await openProxy(tester, settings: settings);

      await tester.enterText(
          find.byType(CupertinoTextField).at(0), 'not a server');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.validatedProxies, ['not a server']);
      expect(settings.savedProxies, isEmpty);
      expect(find.text('Invalid address'), findsOneWidget);
      expect(find.text('Proxy saved'), findsNothing);
    });

    testWidgets('clearing the address skips validation and removes the proxy',
        (tester) async {
      final settings = FakeSettingsViewModel()
        ..proxy = const ProxyConfig(address: 'socks5://127.0.0.1:1080')
        ..proxyActive = true;
      await openProxy(tester, settings: settings);

      await tester.enterText(find.byType(CupertinoTextField).at(0), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.validatedProxies, isEmpty);
      expect(settings.savedProxies.single.address, '');
      expect(find.text('Proxy removed'), findsOneWidget);
      expect(find.text('Not in use'), findsOneWidget);
    });

    testWidgets('a pinned proxy shows no save button', (tester) async {
      await openProxy(tester, settings: FakeSettingsViewModel(proxyFixed: true));

      expect(find.textContaining('deployment pinned this proxy'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
    });

    testWidgets('a hidden proxy cannot be opened at all', (tester) async {
      // A hidden row is not a link, so tapping it must leave the user on the
      // settings list rather than opening a form the deployment forbids.
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(CupertinoApp(
        home: WorkspacePage(
          brightness: Brightness.light,
          onBrightnessChanged: (_) {},
          viewModel: FakeWorkspaceViewModel(),
          settings: FakeSettingsViewModel(proxySettingHidden: true),
          initialSettingsTab: SettingsTab.network,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxy'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Managed by your deployment'), findsWidgets);
      expect(find.text('Server'), findsNothing);
    });
  });
}
