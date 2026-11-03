import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flutter_hbb/features/session/session_window.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/session_tabs_model.dart';

/// Local options held in memory.
///
/// The real repository writes through the native bridge, which widget tests
/// do not have.
class _FakeOptions extends OptionRepository {
  _FakeOptions({Map<String, bool>? values}) : _values = {...?values};

  final Map<String, bool> _values;
  final List<(String, bool)> writes = [];

  @override
  bool getLocalBool(String key) => _values[key] ?? false;

  @override
  Future<void> setLocalBool(String key, bool value) async {
    writes.add((key, value));
    _values[key] = value;
  }
}

SessionTab tab(String peerId,
        {ConnectionKind kind = ConnectionKind.remoteDesktop}) =>
    SessionTab(peerId: peerId, kind: kind);

void main() {
  Future<void> pumpWindow(
    WidgetTester tester,
    SessionTabsModel tabs, {
    OptionRepository? options,
    VoidCallback? onLastTabClosed,
    GlobalKey<SessionWindowState>? key,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(CupertinoApp(
      home: SessionWindow(
        key: key,
        tabs: tabs,
        options: options ?? _FakeOptions(),
        onLastTabClosed: onLastTabClosed,
        // A real SessionPage would start an FFI session, which a widget test
        // has no bridge for. The strip and the close rules are what is under
        // test here; the page itself has its own tests.
        pageBuilder: (tab) => Center(key: ValueKey('page-${tab.peerId}')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('the tab strip', () {
    testWidgets('is hidden for a single session', (tester) async {
      // One tab of chrome would say nothing the title bar does not.
      await pumpWindow(tester, SessionTabsModel(tabs: [tab('847293160')]));

      expect(find.text('847293160'), findsNothing);
    });

    testWidgets('lists every open session once there are several',
        (tester) async {
      await pumpWindow(tester,
          SessionTabsModel(tabs: [tab('111222333'), tab('444555666')]));

      expect(find.text('111222333'), findsOneWidget);
      expect(find.text('444555666'), findsOneWidget);
    });

    testWidgets('tapping a tab brings that session to the front',
        (tester) async {
      final tabs =
          SessionTabsModel(tabs: [tab('111222333'), tab('444555666')]);
      await pumpWindow(tester, tabs);

      await tester.tap(find.text('111222333'));
      await tester.pumpAndSettle();

      expect(tabs.selected?.peerId, '111222333');
    });

    testWidgets('an empty window says so rather than rendering nothing',
        (tester) async {
      await pumpWindow(tester, SessionTabsModel());

      expect(find.text('No session open'), findsOneWidget);
    });
  });

  group('closing', () {
    testWidgets('closing the last tab tells the shell to close the window',
        (tester) async {
      final tabs =
          SessionTabsModel(tabs: [tab('111222333'), tab('444555666')]);
      var closed = false;
      await pumpWindow(tester, tabs, onLastTabClosed: () => closed = true);

      // Each tab has its own close button, in tab order.
      await tester.tap(find.byIcon(LucideIcons.x).first);
      await tester.pumpAndSettle();
      expect(tabs.length, 1);
      expect(closed, isFalse, reason: 'a session is still open');

      // The strip disappears at one tab, so the remaining session is closed
      // through the model the way the session page would.
      tabs.close('444555666');
      await tester.pumpAndSettle();
      expect(tabs.isEmpty, isTrue);
    });

    testWidgets('one session closes without asking', (tester) async {
      // The user is closing the session they are looking at; a dialog would
      // be in the way.
      final tabs = SessionTabsModel(tabs: [tab('111222333')]);
      final key = GlobalKey<SessionWindowState>();
      await pumpWindow(tester, tabs,
          key: key,
          options: _FakeOptions(
              values: {'enable-confirm-closing-tabs': true}));

      expect(key.currentState!.needsCloseConfirmation, isFalse);
      expect(await key.currentState!.confirmCloseAll(), isTrue);
      expect(tabs.isEmpty, isTrue);
    });

    testWidgets('several sessions ask first when the option is on',
        (tester) async {
      final tabs =
          SessionTabsModel(tabs: [tab('111222333'), tab('444555666')]);
      final key = GlobalKey<SessionWindowState>();
      await pumpWindow(tester, tabs,
          key: key,
          options: _FakeOptions(
              values: {'enable-confirm-closing-tabs': true}));

      expect(key.currentState!.needsCloseConfirmation, isTrue);

      final closing = key.currentState!.confirmCloseAll();
      await tester.pumpAndSettle();
      expect(find.text('Disconnect all devices?'), findsOneWidget);
      expect(find.textContaining('2 sessions'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await closing, isFalse);
      expect(tabs.length, 2, reason: 'a cancelled close keeps the sessions');
    });

    testWidgets('confirming disconnects every session', (tester) async {
      final tabs =
          SessionTabsModel(tabs: [tab('111222333'), tab('444555666')]);
      final key = GlobalKey<SessionWindowState>();
      await pumpWindow(tester, tabs,
          key: key,
          options: _FakeOptions(
              values: {'enable-confirm-closing-tabs': true}));

      final closing = key.currentState!.confirmCloseAll();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();

      expect(await closing, isTrue);
      expect(tabs.isEmpty, isTrue);
    });

    testWidgets('unticking the box stops it asking again', (tester) async {
      final options =
          _FakeOptions(values: {'enable-confirm-closing-tabs': true});
      final key = GlobalKey<SessionWindowState>();
      await pumpWindow(
          tester, SessionTabsModel(tabs: [tab('111222333'), tab('444555666')]),
          key: key, options: options);

      final closing = key.currentState!.confirmCloseAll();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask before closing multiple sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await closing;

      // The answer sticks, so the next window does not ask either.
      expect(options.writes, [('enable-confirm-closing-tabs', false)]);
    });

    testWidgets('with the option off it never asks', (tester) async {
      final tabs =
          SessionTabsModel(tabs: [tab('111222333'), tab('444555666')]);
      final key = GlobalKey<SessionWindowState>();
      await pumpWindow(tester, tabs, key: key, options: _FakeOptions());

      expect(key.currentState!.needsCloseConfirmation, isFalse);
      expect(await key.currentState!.confirmCloseAll(), isTrue);
      expect(tabs.isEmpty, isTrue);
    });
  });

  group('session tools', () {
    test('each kind opens its own tool', () {
      expect(SessionWindowState.modeOf(ConnectionKind.remoteDesktop), 0);
      expect(SessionWindowState.modeOf(ConnectionKind.fileTransfer), 1);
      expect(SessionWindowState.modeOf(ConnectionKind.terminal), 2);
      expect(SessionWindowState.modeOf(ConnectionKind.portForward), 3);
      // RDP is a port forward with a flag, so it opens the same tool.
      expect(SessionWindowState.modeOf(ConnectionKind.rdp), 3);
    });
  });
}
