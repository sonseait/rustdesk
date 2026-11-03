import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/features/workspace/workspace_view_model.dart';
import 'package:flutter_hbb/integration/adapters/peer.dart';

void main() {
  group('formatPeerId', () {
    test('groups a numeric id in threes', () {
      expect(formatPeerId('847293160'), '847 293 160');
      expect(formatPeerId('123456789012'), '123 456 789 012');
    });

    test('handles lengths that are not a multiple of three', () {
      expect(formatPeerId('1234'), '1 234');
      expect(formatPeerId('12345'), '12 345');
      expect(formatPeerId('12'), '12');
    });

    test('is idempotent on an already formatted id', () {
      expect(formatPeerId('847 293 160'), '847 293 160');
    });

    test('leaves non-numeric ids alone', () {
      // Alias-style and hosted ids must not be mangled.
      expect(formatPeerId('my-machine'), 'my-machine');
      expect(formatPeerId('123@relay.example'), '123@relay.example');
      expect(formatPeerId(''), '');
    });
  });

  group('PeerScope', () {
    test('local scopes map to a peer list source', () {
      expect(PeerScope.recent.source, PeerSource.recent);
      expect(PeerScope.favorite.source, PeerSource.favorite);
      expect(PeerScope.discovered.source, PeerSource.lan);
    });

    test('server-backed scopes have no local source', () {
      // These are served by the address book and group caches, so removing a
      // peer locally would be wrong.
      expect(PeerScope.addressBook.source, isNull);
      expect(PeerScope.group.source, isNull);
    });

    test('every scope has a label', () {
      for (final scope in PeerScope.values) {
        expect(scope.label, isNotEmpty, reason: '$scope');
      }
    });
  });

  group('IdentityView', () {
    test('reports loading before the first read', () {
      const view = IdentityView(
        deviceId: '',
        isLoading: true,
        isOnline: false,
        isServiceRunning: false,
        temporaryPassword: '',
      );

      expect(view.isLoading, isTrue);
      expect(view.formattedDeviceId, isEmpty);
      expect(view.hasError, isFalse);
    });

    test('formats a loaded device id', () {
      const view = IdentityView(
        deviceId: '847293160',
        isLoading: false,
        isOnline: true,
        isServiceRunning: true,
        temporaryPassword: 'abc123',
      );

      expect(view.formattedDeviceId, '847 293 160');
      expect(view.isOnline, isTrue);
    });

    test('carries an error alongside stale values', () {
      const view = IdentityView(
        deviceId: '847293160',
        isLoading: false,
        isOnline: false,
        isServiceRunning: true,
        temporaryPassword: '',
        error: 'boom',
      );

      expect(view.hasError, isTrue);
      // The id is still shown rather than blanked.
      expect(view.formattedDeviceId, '847 293 160');
    });
  });

  group('LoadState semantics', () {
    test('distinguishes loading from empty', () {
      // The workspace must never render "no devices" while still loading.
      expect(LoadState.values, containsAll([
        LoadState.loading,
        LoadState.ready,
        LoadState.empty,
        LoadState.error,
      ]));
    });
  });
}
