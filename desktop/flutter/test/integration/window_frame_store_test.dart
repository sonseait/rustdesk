import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/routing/window_coordinator.dart';
import 'package:flutter_hbb/integration/routing/window_frame_store.dart';

/// A store over in-memory frames.
///
/// The real store reads through the native bridge, which unit tests do not
/// have. Only the storage is replaced; the restore rules under test are the
/// real ones.
class _FakeStore extends WindowFrameStore {
  _FakeStore({
    this.saved = const {},
    this.peerSaved = const {},
    this.restoreDisabled = false,
  });

  final Map<WindowType, WindowFrame> saved;
  final Map<String, WindowFrame> peerSaved;
  final bool restoreDisabled;

  final List<WindowFrame> writes = [];
  final List<(String, WindowFrame)> peerWrites = [];

  @override
  bool get isRestoreDisabled => restoreDisabled;

  @override
  WindowFrame? frameOf(WindowType type) => saved[type];

  @override
  WindowFrame? peerFrameOf(WindowType type, String peerId) =>
      peerSaved[peerId];

  @override
  Future<void> saveFrame(WindowType type, WindowFrame frame) async =>
      writes.add(frame);

  @override
  void savePeerFrame(WindowType type, String peerId, WindowFrame frame) =>
      peerWrites.add((peerId, frame));
}

void main() {
  group('WindowFrame', () {
    // These JSON keys are what the core already has on disk. A rename loses
    // every saved window position silently.
    test('round-trips through the stored JSON', () {
      const frame = WindowFrame(
        width: 1280,
        height: 720,
        offsetWidth: 100,
        offsetHeight: 50,
        isMaximized: false,
        isFullscreen: true,
      );

      final parsed = WindowFrame.parse(frame.toString());

      expect(parsed, frame);
    });

    test('uses the legacy key names', () {
      const frame = WindowFrame(width: 1, height: 2, offsetWidth: 3);

      final json = frame.toJson();

      expect(json.keys,
          containsAll(['width', 'height', 'offsetWidth', 'offsetHeight']));
      expect(json.keys, containsAll(['isMaximized', 'isFullscreen']));
    });

    test('nothing saved parses to null, not an empty frame', () {
      expect(WindowFrame.parse(''), isNull);
    });

    test('malformed content parses to null rather than throwing', () {
      expect(WindowFrame.parse('not json'), isNull);
      expect(WindowFrame.parse('[1,2,3]'), isNull);
    });

    test('an integer size from the config is read as a double', () {
      // The core writes whatever JSON it was handed; a whole number arrives
      // as int and must not be dropped.
      final parsed = WindowFrame.parse('{"width":1280,"height":720}');

      expect(parsed?.width, 1280.0);
      expect(parsed?.height, 720.0);
    });

    test('shifting moves both offsets and leaves the size alone', () {
      const frame =
          WindowFrame(width: 800, height: 600, offsetWidth: 10, offsetHeight: 20);

      final shifted = frame.shifted(30);

      expect(shifted.offsetWidth, 40);
      expect(shifted.offsetHeight, 50);
      expect(shifted.width, 800);
    });

    test('shifting a frame with no offset leaves it without one', () {
      const frame = WindowFrame(width: 800, height: 600);

      expect(frame.shifted(30).offsetWidth, isNull);
    });
  });

  group('restoring a frame', () {
    test('returns nothing when the deployment disabled restore', () {
      final store = _FakeStore(
        saved: const {
          WindowType.Main: WindowFrame(width: 800, height: 600),
        },
        restoreDisabled: true,
      );

      expect(store.restoreFrame(WindowType.Main), isNull);
    });

    test('returns nothing when no frame was ever saved', () {
      expect(_FakeStore().restoreFrame(WindowType.Main), isNull);
    });

    test('a peer keeps its own frame, unshifted', () {
      // The peer's frame already describes where that session belongs, so
      // staggering it would move a window the user deliberately placed.
      final store = _FakeStore(
        saved: const {
          WindowType.RemoteDesktop:
              WindowFrame(width: 800, height: 600, offsetWidth: 0, offsetHeight: 0)
        },
        peerSaved: const {
          '847293160': WindowFrame(
              width: 1024, height: 768, offsetWidth: 300, offsetHeight: 200)
        },
      );

      final frame = store.restoreFrame(WindowType.RemoteDesktop,
          windowId: 3, peerId: '847293160');

      expect(frame?.width, 1024);
      expect(frame?.offsetWidth, 300);
    });

    test('a shared frame is staggered so windows do not stack', () {
      final store = _FakeStore(saved: const {
        WindowType.RemoteDesktop: WindowFrame(
            width: 800, height: 600, offsetWidth: 100, offsetHeight: 100)
      });

      final frame =
          store.restoreFrame(WindowType.RemoteDesktop, windowId: 2);

      expect(frame?.offsetWidth, 100 + 2 * kNewWindowOffset);
      expect(frame?.offsetHeight, 100 + 2 * kNewWindowOffset);
    });

    test('a window type without per-peer frames is not staggered', () {
      final store = _FakeStore(saved: const {
        WindowType.FileTransfer: WindowFrame(
            width: 800, height: 600, offsetWidth: 100, offsetHeight: 100)
      });

      final frame = store.restoreFrame(WindowType.FileTransfer, windowId: 2);

      expect(frame?.offsetWidth, 100);
    });

    test('an absurd saved size comes back as the default', () {
      // A saved frame can be nonsense after a display change; restoring it
      // literally would open a window larger than every screen.
      final store = _FakeStore(saved: const {
        WindowType.Main: WindowFrame(width: 99999, height: 0)
      });

      final frame = store.restoreFrame(WindowType.Main);

      expect(frame?.width, 1280);
      expect(frame?.height, 720);
    });

    test('an off-screen position is dropped so the window is centred', () {
      final store = _FakeStore(saved: const {
        WindowType.Main: WindowFrame(
            width: 800, height: 600, offsetWidth: 99999, offsetHeight: 99999)
      });

      final frame = store.restoreFrame(WindowType.Main);

      expect(frame, isNotNull);
      // Null offset means "let the platform place it", which the caller
      // turns into a centred window.
      expect(frame?.offset, isNull);
      expect(frame?.width, 800);
    });

    test('a position above the desktop is dropped', () {
      final store = _FakeStore(saved: const {
        WindowType.Main: WindowFrame(
            width: 800, height: 600, offsetWidth: 100, offsetHeight: -500)
      });

      expect(store.restoreFrame(WindowType.Main)?.offset, isNull);
    });

    test('a window mostly off the left edge is dropped', () {
      final store = _FakeStore(saved: const {
        WindowType.Main: WindowFrame(
            width: 800, height: 600, offsetWidth: -900, offsetHeight: 100)
      });

      expect(store.restoreFrame(WindowType.Main)?.offset, isNull);
    });

    test('a sensible position is kept as it is', () {
      final store = _FakeStore(saved: const {
        WindowType.Main: WindowFrame(
            width: 800, height: 600, offsetWidth: 120, offsetHeight: 80)
      });

      final frame = store.restoreFrame(WindowType.Main);

      expect(frame?.offset?.dx, 120);
      expect(frame?.offset?.dy, 80);
    });
  });

  group('saving a peer frame', () {
    test('an ordinary frame is stored as it is', () {
      final store = _FakeStore();
      const frame = WindowFrame(
          width: 800,
          height: 600,
          offsetWidth: 10,
          offsetHeight: 20,
          isMaximized: false,
          isFullscreen: false);

      final saved =
          store.peerFrameToSave(WindowType.RemoteDesktop, 'peer', frame);

      expect(saved, frame);
    });

    test('a maximised window keeps the size it would return to', () {
      // A maximised window reports the screen's size, so storing it would
      // un-maximise later to the size of the whole screen.
      final store = _FakeStore(peerSaved: const {
        'peer': WindowFrame(
            width: 900, height: 700, offsetWidth: 40, offsetHeight: 60)
      });
      const maximised = WindowFrame(
          width: 3840,
          height: 2160,
          offsetWidth: 0,
          offsetHeight: 0,
          isMaximized: true,
          isFullscreen: false);

      final saved =
          store.peerFrameToSave(WindowType.RemoteDesktop, 'peer', maximised);

      expect(saved.width, 900);
      expect(saved.offsetWidth, 40);
      expect(saved.isMaximized, isTrue);
    });

    test('a fullscreen window with no earlier frame keeps what it has', () {
      final store = _FakeStore();
      const fullscreen = WindowFrame(
          width: 3840, height: 2160, isMaximized: false, isFullscreen: true);

      final saved =
          store.peerFrameToSave(WindowType.RemoteDesktop, 'peer', fullscreen);

      expect(saved.width, 3840);
      expect(saved.isFullscreen, isTrue);
    });
  });

  group('window titles', () {
    // A user with several windows open tells them apart from the title bar.
    test('name the tool and the peer', () {
      expect(WindowCoordinator.titleFor(WindowType.RemoteDesktop, '847293160'),
          'RustDesk · Remote desktop · 847293160');
      expect(WindowCoordinator.titleFor(WindowType.Terminal, '847293160'),
          'RustDesk · Terminal · 847293160');
    });

    test('drop the peer when there is none', () {
      expect(WindowCoordinator.titleFor(WindowType.FileTransfer, ''),
          'RustDesk · File transfer');
    });

    test('the main window is just the product name', () {
      expect(WindowCoordinator.titleFor(WindowType.Main, ''), 'RustDesk');
      expect(WindowCoordinator.titleFor(WindowType.Unknown, 'peer'), 'RustDesk');
    });
  });
}
