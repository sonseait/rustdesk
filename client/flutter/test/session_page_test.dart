import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/features/session/session_page.dart';
import 'package:flutter_hbb/features/session/session_view_model.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';
import 'package:flutter_hbb/integration/session/session_adapter.dart';

import 'integration/peer_info_test.dart' show display, peerInfoEvent;
import 'package:flutter_hbb/integration/session/session_options.dart';

import 'support/fake_session_view_model.dart';

Future<FakeSessionViewModel> pumpSession(
  WidgetTester tester, {
  FakeSessionViewModel? model,
}) async {
  final viewModel = model ?? FakeSessionViewModel();
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(CupertinoApp(
    home: SessionPage(remoteId: '847293160', viewModel: viewModel),
  ));
  await tester.pumpAndSettle();
  return viewModel;
}

void main() {
  group('session stages', () {
    testWidgets('shows connecting before the first frame', (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
              stageOverride: SessionStage.connecting));

      expect(find.text('Connecting'), findsOneWidget);
    });

    testWidgets('shows a failure with a reconnect action', (tester) async {
      final model = await pumpSession(tester,
          model: FakeSessionViewModel(stageOverride: SessionStage.failed));

      // The status appears in the canvas and the toolbar.
      expect(find.text('Connection failed'), findsWidgets);

      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();

      expect(model.reconnects, 1);
    });

    testWidgets('shows a closed session with a reconnect action',
        (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(stageOverride: SessionStage.closed));

      expect(find.text('Session closed'), findsWidgets);
      expect(find.text('Reconnect'), findsOneWidget);
    });

    testWidgets('asks for a password when the core prompts', (tester) async {
      final model = await pumpSession(tester,
          model: FakeSessionViewModel(
            stageOverride: SessionStage.prompt,
            promptOverride: const SessionPrompt(
                type: 'input-password',
                title: 'Password required',
                text: ''),
          ));

      expect(find.text('Authentication required'), findsOneWidget);

      await tester.enterText(find.byType(CupertinoTextField), 'hunter2');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(model.submittedPasswords, ['hunter2']);
    });

    testWidgets('asks for a code on a two-factor prompt', (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
            stageOverride: SessionStage.prompt,
            promptOverride:
                const SessionPrompt(type: 'input-2fa', title: '2FA', text: ''),
          ));

      expect(find.text('Two-factor code'), findsOneWidget);
      // A code is not a password, so there is no remember option.
      expect(find.text('Remember this password'), findsNothing);
    });
  });

  group('toolbar', () {
    testWidgets('shows the real host and connection state', (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
            peerInfoOverride:
                PeerInfo.fromEvent(peerInfoEvent(displays: [display()])),
            secure: true,
            direct: true,
          ));

      expect(find.textContaining('workstation'), findsWidgets);
      expect(find.textContaining('Encrypted'), findsWidgets);
    });

    testWidgets('reports a relayed, unencrypted session honestly',
        (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(secure: false, direct: false));

      expect(find.textContaining('Not encrypted'), findsWidgets);
      expect(find.textContaining('Relayed'), findsWidgets);
    });

    testWidgets('toggles view only', (tester) async {
      final model = await pumpSession(tester);
      expect(model.isViewOnly, isFalse);

      await tester.tap(find.byIcon(LucideIcons.mousePointer2));
      await tester.pumpAndSettle();

      expect(model.isViewOnly, isTrue);
    });

    testWidgets('hides the display picker for a single display',
        (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
              peerInfoOverride: PeerInfo.fromEvent(
                  peerInfoEvent(displays: [display()]))));

      expect(find.byIcon(LucideIcons.monitorSmartphone), findsNothing);
    });

    testWidgets('shows the display picker for multiple displays',
        (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
              peerInfoOverride: PeerInfo.fromEvent(peerInfoEvent(
                  displays: [display(), display(x: 1920)]))));

      expect(find.byIcon(LucideIcons.monitorSmartphone), findsOneWidget);
    });

    testWidgets('switches display through the model', (tester) async {
      final model = await pumpSession(tester,
          model: FakeSessionViewModel(
              peerInfoOverride: PeerInfo.fromEvent(peerInfoEvent(
                  displays: [display(), display(x: 1920)]))));

      await tester.tap(find.byIcon(LucideIcons.monitorSmartphone));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Display 2'));
      await tester.pumpAndSettle();

      expect(model.displaySwitches, [1]);
    });

    testWidgets('switches to all displays', (tester) async {
      final model = await pumpSession(tester,
          model: FakeSessionViewModel(
              peerInfoOverride: PeerInfo.fromEvent(peerInfoEvent(
                  displays: [display(), display(x: 1920)]))));

      await tester.tap(find.byIcon(LucideIcons.monitorSmartphone));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All displays'));
      await tester.pumpAndSettle();

      expect(model.displaySwitches, [kAllDisplayValue]);
    });

    testWidgets('changes the view style', (tester) async {
      final model = await pumpSession(tester);

      await tester.tap(find.byIcon(LucideIcons.scaling));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original size'));
      await tester.pumpAndSettle();

      expect(model.viewStyles, [kRemoteViewStyleOriginal]);
    });
  });

  group('details panel', () {
    testWidgets('shows peer-reported facts, not assumptions', (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
            peerInfoOverride:
                PeerInfo.fromEvent(peerInfoEvent(displays: [display()])),
            secure: false,
            direct: false,
          ));

      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pumpAndSettle();

      expect(find.text('Session details'), findsOneWidget);
      expect(find.text('workstation'), findsWidgets);
      expect(find.text('Windows'), findsWidgets);
      // The old panel claimed 'Encrypted' unconditionally.
      expect(find.text('Not encrypted'), findsWidgets);
      expect(find.text('Relayed'), findsWidgets);
    });

    testWidgets('reports view-only input state', (tester) async {
      final model = await pumpSession(tester);
      model.setViewOnly(true);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.info));
      await tester.pumpAndSettle();

      expect(find.text('View only'), findsOneWidget);
    });
  });

  group('session tools', () {
    testWidgets('the chat panel opens and closes from the toolbar',
        (tester) async {
      await pumpSession(tester);
      expect(find.text('Chat'), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.messageSquare).first);
      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('No messages yet'), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.x).last);
      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsNothing);
    });

    testWidgets('an incoming message is badged until the panel opens',
        (tester) async {
      final model = await pumpSession(tester);

      model.chat.handleEvent({'name': 'chat_client_mode', 'text': 'ping'});
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.messageSquare).first);
      await tester.pumpAndSettle();

      expect(find.text('ping'), findsOneWidget);
      // Opening the panel clears the badge.
      expect(model.unreadChatCount, 0);
    });

    testWidgets('the file tool explains itself before the session is live',
        (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
              stageOverride: SessionStage.connecting));

      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();

      // No file panes until there is a session to list the remote side.
      expect(find.text('Files'), findsWidgets);
      expect(find.text('This folder is empty'), findsNothing);
    });

    testWidgets('the terminal explains itself before the session is live',
        (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
              stageOverride: SessionStage.connecting));

      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();

      expect(find.text('Terminal'), findsWidgets);
      expect(find.text('Starting a shell…'), findsNothing);
    });
  });

  group('session options', () {
    testWidgets('toggling audio calls through to the core', (tester) async {
      final model = await pumpSession(tester);

      await tester.tap(find.byIcon(LucideIcons.settings2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();

      final options = model.options as FakeSessionOptions;
      expect(options.toggled, [SessionToggle.disableAudio]);
    });

    testWidgets('the menu offers every session switch', (tester) async {
      await pumpSession(tester);

      await tester.tap(find.byIcon(LucideIcons.settings2));
      await tester.pumpAndSettle();

      expect(find.text('Audio'), findsOneWidget);
      expect(find.text('Clipboard'), findsOneWidget);
      expect(find.text('Privacy mode'), findsOneWidget);
      expect(find.text('Start recording'), findsOneWidget);
      expect(find.text('Balanced'), findsOneWidget);
    });

    testWidgets('recording flips its label once started', (tester) async {
      final model = await pumpSession(tester);

      await tester.tap(find.byIcon(LucideIcons.settings2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start recording'));
      await tester.pumpAndSettle();

      expect(model.options.isRecording, isTrue);

      // Reopening shows the flipped label.
      await tester.tap(find.byIcon(LucideIcons.settings2).first);
      await tester.pumpAndSettle();
      expect(find.text('Stop recording'), findsOneWidget);
    });

    testWidgets('choosing a quality preset sends its stored value',
        (tester) async {
      final model = await pumpSession(tester);

      await tester.tap(find.byIcon(LucideIcons.settings2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Best speed'));
      await tester.pumpAndSettle();

      final options = model.options as FakeSessionOptions;
      expect(options.qualities, ['low']);
    });
  });

  group('SessionToggle contract', () {
    test('inverted switches are the ones stored as "disable"', () {
      // The toolbar shows "Audio"; the core stores "disable_audio". Getting
      // this backwards makes every such switch read inverted.
      expect(SessionToggle.disableAudio.inverted, isTrue);
      expect(SessionToggle.disableClipboard.inverted, isTrue);
      expect(SessionToggle.privacyMode.inverted, isFalse);
      expect(SessionToggle.viewOnly.inverted, isFalse);
    });

    test('the option keys match the Rust contract', () {
      // Several use underscores; normalizing them to dashes loses the value.
      expect(SessionToggle.disableAudio.key, 'disable_audio');
      expect(SessionToggle.disableClipboard.key, 'disable_clipboard');
      expect(SessionToggle.privacyMode.key, 'privacy_mode');
      expect(SessionToggle.lockAfterSessionEnd.key, 'lock_after_session_end');
      expect(SessionToggle.fileCopyPaste.key, 'enable-file-copy-paste');
      expect(SessionToggle.swapLeftRightMouse.key, 'swap-left-right-mouse');
    });
  });

  group('port forwarding', () {
    Future<FakeSessionViewModel> pumpTunnels(WidgetTester tester,
        {FakeSessionViewModel? model}) async {
      final viewModel = await pumpSession(tester, model: model);
      await tester.tap(find.text('Tunnels'));
      await tester.pumpAndSettle();
      return viewModel;
    }

    testWidgets('shows an empty state before any tunnel exists',
        (tester) async {
      await pumpTunnels(tester);

      expect(find.text('No tunnels yet'), findsOneWidget);
    });

    testWidgets('lists existing tunnels with both ends', (tester) async {
      final model = await pumpSession(tester);
      await (model.portForwards as FakePortForwardModel)
          .add(localPort: 8080, remoteHost: 'db', remotePort: 5432);
      await tester.tap(find.text('Tunnels'));
      await tester.pumpAndSettle();

      expect(find.text('localhost:8080'), findsOneWidget);
      expect(find.text('→ db:5432'), findsOneWidget);
    });

    testWidgets('adds a tunnel through the dialog', (tester) async {
      final model = await pumpTunnels(tester);

      await tester.tap(find.text('Add tunnel'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).at(0), '9000');
      await tester.enterText(find.byType(CupertinoTextField).at(1), 'app');
      await tester.enterText(find.byType(CupertinoTextField).at(2), '80');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final forwards = (model.portForwards as FakePortForwardModel).rules;
      expect(forwards.single.localPort, 9000);
      expect(forwards.single.remoteHost, 'app');
      expect(forwards.single.remotePort, 80);
    });

    testWidgets('rejects a port outside the valid range', (tester) async {
      final model = await pumpTunnels(tester);

      await tester.tap(find.text('Add tunnel'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).at(0), '70000');
      await tester.enterText(find.byType(CupertinoTextField).at(2), '80');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // The dialog stays open with an explanation rather than sending a rule
      // the core would refuse.
      expect(find.textContaining('between 1 and 65535'), findsOneWidget);
      expect((model.portForwards as FakePortForwardModel).rules, isEmpty);
    });

    testWidgets('removes a tunnel', (tester) async {
      final model = await pumpSession(tester);
      final forwards = model.portForwards as FakePortForwardModel;
      await forwards.add(
          localPort: 8080, remoteHost: 'db', remotePort: 5432);
      await tester.tap(find.text('Tunnels'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.trash2));
      await tester.pumpAndSettle();

      expect(forwards.removed, [8080]);
      expect(find.text('No tunnels yet'), findsOneWidget);
    });

    testWidgets('opens RDP through the model', (tester) async {
      final model = await pumpTunnels(tester);

      await tester.tap(find.text('Open RDP'));
      await tester.pumpAndSettle();

      expect((model.portForwards as FakePortForwardModel).rdpOpened, 1);
    });

    testWidgets('explains itself before the session is live', (tester) async {
      await pumpSession(tester,
          model: FakeSessionViewModel(
              stageOverride: SessionStage.connecting));
      await tester.tap(find.text('Tunnels'));
      await tester.pumpAndSettle();

      expect(find.text('Port forwarding'), findsWidgets);
      expect(find.text('No tunnels yet'), findsNothing);
    });
  });
}
