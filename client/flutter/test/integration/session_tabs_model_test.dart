import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/routing/connection_request.dart';
import 'package:flutter_hbb/integration/routing/session_tabs_model.dart';

SessionTab tab(String peerId,
        {ConnectionKind kind = ConnectionKind.remoteDesktop}) =>
    SessionTab(peerId: peerId, kind: kind);

void main() {
  group('adding tabs', () {
    test('a new peer opens a tab and comes to the front', () {
      final tabs = SessionTabsModel(tabs: [tab('111')]);

      expect(tabs.add(tab('222')), isTrue);
      expect(tabs.length, 2);
      expect(tabs.selected?.peerId, '222');
    });

    test('an already-open peer selects its tab instead of duplicating it', () {
      // Reconnecting to an open peer must not start a second session against
      // it; the existing one is what the user meant.
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222')]);
      tabs.select(1);

      expect(tabs.add(tab('111')), isFalse);
      expect(tabs.length, 2);
      expect(tabs.selected?.peerId, '111');
    });

    test('adding notifies once', () {
      final tabs = SessionTabsModel();
      var notifications = 0;
      tabs.addListener(() => notifications++);

      tabs.add(tab('111'));

      expect(notifications, 1);
    });
  });

  group('selecting', () {
    test('an out-of-range index is clamped rather than throwing', () {
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222')]);

      tabs.select(9);

      expect(tabs.selectedIndex, 1);
    });

    test('selecting the current tab does not notify', () {
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222')]);
      tabs.select(0);
      var notifications = 0;
      tabs.addListener(() => notifications++);

      tabs.select(0);

      expect(notifications, 0);
    });

    test('selecting an unknown peer changes nothing', () {
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222')]);
      tabs.select(0);

      tabs.selectPeer('999');

      expect(tabs.selectedIndex, 0);
    });
  });

  group('closing', () {
    test('closing the selected tab falls back to the one before it', () {
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222'), tab('333')]);
      tabs.select(2);

      expect(tabs.close('333'), isTrue);
      expect(tabs.selected?.peerId, '222');
    });

    test('closing the first tab keeps the selection in range', () {
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222')]);
      tabs.select(0);

      tabs.close('111');

      expect(tabs.selectedIndex, 0);
      expect(tabs.selected?.peerId, '222');
    });

    test('closing a background tab leaves the front one in front', () {
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222'), tab('333')]);
      tabs.select(2);

      tabs.close('111');

      expect(tabs.selected?.peerId, '333');
    });

    test('closing the last tab empties the window', () {
      final tabs = SessionTabsModel(tabs: [tab('111')]);

      tabs.close('111');

      expect(tabs.isEmpty, isTrue);
      expect(tabs.selected, isNull);
    });

    test('closing an unknown peer reports that nothing happened', () {
      final tabs = SessionTabsModel(tabs: [tab('111')]);

      expect(tabs.close('999'), isFalse);
      expect(tabs.length, 1);
    });

    test('closing all empties the window in one notification', () {
      final tabs = SessionTabsModel(tabs: [tab('111'), tab('222')]);
      var notifications = 0;
      tabs.addListener(() => notifications++);

      tabs.closeAll();

      expect(tabs.isEmpty, isTrue);
      expect(notifications, 1);
    });
  });

  group('window events', () {
    // The payload is what WindowCoordinator sends, so these keys are the
    // existing multi-window contract.
    String payload(Map<String, dynamic> extra) =>
        jsonEncode({'id': '847293160', ...extra});

    test('a remote desktop event opens that session', () {
      final result = SessionTabsModel.tabFromEvent(
          kWindowEventNewRemoteDesktop, payload({'password': 'hunter2'}));

      expect(result?.peerId, '847293160');
      expect(result?.kind, ConnectionKind.remoteDesktop);
      expect(result?.password, 'hunter2');
    });

    test('each event maps to its own kind', () {
      expect(
          SessionTabsModel.tabFromEvent(
                  kWindowEventNewFileTransfer, payload(const {}))
              ?.kind,
          ConnectionKind.fileTransfer);
      expect(
          SessionTabsModel.tabFromEvent(
                  kWindowEventNewTerminal, payload(const {}))
              ?.kind,
          ConnectionKind.terminal);
      expect(
          SessionTabsModel.tabFromEvent(
                  kWindowEventNewViewCamera, payload(const {}))
              ?.kind,
          ConnectionKind.viewCamera);
    });

    test('a port-forward event with the RDP flag is an RDP session', () {
      // RDP and port forward share a window type; the flag is what tells them
      // apart, and losing it would open the wrong tool.
      final result = SessionTabsModel.tabFromEvent(
          kWindowEventNewPortForward, payload({'isRDP': true}));

      expect(result?.kind, ConnectionKind.rdp);
    });

    test('a port-forward event without the flag stays a port forward', () {
      final result = SessionTabsModel.tabFromEvent(
          kWindowEventNewPortForward, payload(const {}));

      expect(result?.kind, ConnectionKind.portForward);
    });

    test('the relay and token flags survive the round trip', () {
      final result = SessionTabsModel.tabFromEvent(
          kWindowEventNewRemoteDesktop,
          payload({'forceRelay': true, 'connToken': 'abc'}));

      expect(result?.forceRelay, isTrue);
      expect(result?.connToken, 'abc');
    });

    test('an unrelated method is not a session', () {
      expect(
          SessionTabsModel.tabFromEvent(kWindowEventActiveSession, '847293160'),
          isNull);
    });

    test('a payload with no peer is not a session', () {
      expect(
          SessionTabsModel.tabFromEvent(
              kWindowEventNewRemoteDesktop, jsonEncode(const {'id': ''})),
          isNull);
    });

    test('malformed arguments do not throw', () {
      expect(
          SessionTabsModel.tabFromEvent(
              kWindowEventNewRemoteDesktop, 'not json'),
          isNull);
    });
  });
}
