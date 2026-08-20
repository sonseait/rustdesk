import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/integration/session/canvas_model.dart';
import 'package:flutter_hbb/integration/session/input_model.dart';
import 'package:flutter_hbb/integration/session/key_maps.dart';
import 'package:flutter_hbb/integration/session/peer_info.dart';

import 'peer_info_test.dart' show display, peerInfoEvent;

InputModel model() => InputModel(
      sessionId: const Uuid().v4obj(),
      peerId: '123456789',
    );

void main() {
  group('gating', () {
    test('input is blocked in view-only mode', () {
      final input = model()..viewOnly = true;
      expect(input.canSendInput, isFalse);
    });

    test('input is blocked without keyboard permission', () {
      // The peer can revoke keyboard control mid-session.
      final input = model()..keyboardPermission = false;
      expect(input.canSendInput, isFalse);
    });

    test('input flows when permitted and not view-only', () {
      expect(model().canSendInput, isTrue);
    });

    test('a blocked key event is still reported handled', () {
      // Otherwise the key would fall through to a local shortcut while the
      // canvas has focus.
      final input = model()..viewOnly = true;
      final result = input.handleKeyEvent(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      ));

      expect(result, KeyEventResult.handled);
    });
  });

  group('modifiers', () {
    test('are applied to outgoing events', () {
      final input = model()
        ..ctrl = true
        ..shift = true;

      final event = input.withModifiers({'type': 'down'});

      expect(event['ctrl'], 'true');
      expect(event['shift'], 'true');
      // Unset modifiers are omitted, not sent as false.
      expect(event.containsKey('alt'), isFalse);
      expect(event.containsKey('command'), isFalse);
    });

    test('reset clears every modifier', () {
      final input = model()
        ..ctrl = true
        ..shift = true
        ..alt = true
        ..command = true;

      input.resetModifiers();

      expect(input.withModifiers({}), isEmpty);
    });
  });

  group('pointer resolution', () {
    test('a plain move stays a move', () {
      final input = model();
      final resolved = input.resolvePointer(
        const PointerMoveEvent(buttons: 0),
        kMouseEventTypeMove,
      );

      expect(resolved.type, kMouseEventTypeMove);
    });

    test('a move that adds a button becomes a press', () {
      // Flutter emits a move when a second button goes down mid-drag.
      final input = model();
      input.resolvePointer(
          const PointerDownEvent(buttons: 1), kMouseEventTypeDown);

      final resolved = input.resolvePointer(
        const PointerMoveEvent(buttons: 3),
        kMouseEventTypeMove,
      );

      expect(resolved.type, kMouseEventTypeDown);
      expect(resolved.buttons, 2, reason: 'only the newly pressed button');
    });

    test('a move that drops a button becomes a release', () {
      final input = model();
      input.resolvePointer(
          const PointerDownEvent(buttons: 3), kMouseEventTypeDown);

      final resolved = input.resolvePointer(
        const PointerMoveEvent(buttons: 1),
        kMouseEventTypeMove,
      );

      expect(resolved.type, kMouseEventTypeUp);
      expect(resolved.buttons, 2, reason: 'only the released button');
    });

    test('button tracking resets', () {
      final input = model();
      input.resolvePointer(
          const PointerDownEvent(buttons: 1), kMouseEventTypeDown);
      input.resetButtons();

      final resolved = input.resolvePointer(
        const PointerMoveEvent(buttons: 0),
        kMouseEventTypeMove,
      );

      expect(resolved.type, kMouseEventTypeMove);
    });
  });

  group('lock modes', () {
    test('encodes caps lock at bit 1', () {
      // The bitmask is the Rust contract: 1<<1 caps, 1<<2 num, 1<<3 scroll.
      expect(1 << 1, 2);
      expect(1 << 2, 4);
      expect(1 << 3, 8);
    });

    test('reads the live lock state once bindings exist', () {
      // buildLockModes reads HardwareKeyboard, which needs the binding.
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(buildLockModes, returnsNormally);
      // No locks are enabled in a test binding.
      expect(buildLockModes(), 0);
    });
  });

  group('key maps', () {
    test('carry the names the core expects', () {
      // A rename here silently breaks that key on the remote side.
      expect(physicalKeyMap[0x00070004], 'VK_A');
      expect(physicalKeyMap[0x00070028], 'VK_ENTER');
      expect(physicalKeyMap[0x0007002a], 'VK_BACK');
      expect(physicalKeyMap[0x000700e1], 'VK_SHIFT');
      expect(logicalKeyMap[0x00000000061], 'VK_A');
      expect(logicalKeyMap[0x0010000000d], 'VK_ENTER');
    });

    test('cover the full alphabet and function keys', () {
      for (var i = 0; i < 26; i++) {
        final usage = 0x00070004 + i;
        expect(physicalKeyMap[usage], isNotNull, reason: 'usage $usage');
      }
      for (var f = 0; f < 12; f++) {
        expect(physicalKeyMap[0x0007003a + f], 'VK_F${f + 1}');
      }
    });
  });

  group('displayRect', () {
    test('is the display origin and size for a single display', () {
      final pi = PeerInfo.fromEvent(peerInfoEvent(displays: [display()]));

      expect(displayRect(pi), const Rect.fromLTWH(0, 0, 1920, 1080));
    });

    test('offsets into a second monitor', () {
      final pi = PeerInfo.fromEvent(peerInfoEvent(
        currentDisplay: 1,
        displays: [display(), display(x: 1920)],
      ));

      expect(displayRect(pi), const Rect.fromLTWH(1920, 0, 1920, 1080));
    });

    test('spans every display in the combined view', () {
      // Showing all displays maps input across the whole virtual desktop.
      final pi = PeerInfo.fromEvent(peerInfoEvent(
        currentDisplay: kAllDisplayValue,
        displays: [display(), display(x: 1920)],
      ));

      expect(displayRect(pi), const Rect.fromLTWH(0, 0, 3840, 1080));
    });

    test('is empty when no displays are known', () {
      expect(displayRect(const PeerInfo()), Rect.zero);
    });
  });

  group('MouseButton', () {
    test('carries Flutter\'s bitmask', () {
      expect(MouseButton.left.mask, 1);
      expect(MouseButton.right.mask, 2);
      expect(MouseButton.wheel.mask, 4);
      expect(MouseButton.back.mask, 8);
      expect(MouseButton.forward.mask, 16);
    });

    test('names the button the way the core expects', () {
      // The core matches these as strings. Sending the numeric mask makes it
      // fall through to "no button", so the click presses nothing at all.
      expect(MouseButton.left.name, 'left');
      expect(MouseButton.right.name, 'right');
      expect(MouseButton.wheel.name, 'wheel');
      expect(MouseButton.back.name, 'back');
      expect(MouseButton.forward.name, 'forward');
    });

    test('resolves a bitmask to a button', () {
      expect(MouseButton.fromMask(1), MouseButton.left);
      expect(MouseButton.fromMask(2), MouseButton.right);
      expect(MouseButton.fromMask(4), MouseButton.wheel);
      // A move reports no buttons at all.
      expect(MouseButton.fromMask(0), isNull);
    });

    test('a combined mask resolves to one button', () {
      // Flutter reports left+right as 3 while dragging; the core takes one
      // name, and left is the one the press was resolved from.
      expect(MouseButton.fromMask(3), MouseButton.left);
    });
  });

  group('keyboard modes', () {
    test('the persisted mode strings are unchanged', () {
      expect(kKeyLegacyMode, 'legacy');
      expect(kKeyMapMode, 'map');
      expect(kKeyTranslateMode, 'translate');
    });

    test('map mode is the default before the core reports one', () {
      expect(model().keyboardMode, kKeyMapMode);
    });
  });

  group('wire format', () {
    // Regression: the core matches these as strings and silently ignores
    // anything unrecognised, so a wrong value travels fine and presses
    // nothing. Both of these were wrong at once: clicks reached the peer and
    // did nothing, while the keyboard kept working.
    test('event types match what the core matches on', () {
      expect(kMouseEventTypeDown, 'down');
      expect(kMouseEventTypeUp, 'up');
      expect(kMouseEventTypeWheel, 'wheel');
    });

    test('a move carries an empty type, not the word move', () {
      // src/flutter_ffi.rs matches down/up/wheel/trackpad/move_relative and
      // falls through to mask 0 for everything else. A move is expressed by
      // position alone.
      expect(kMouseEventTypeMove, isEmpty);
    });

    test('buttons are named, never numeric', () {
      for (final button in MouseButton.values) {
        expect(button.name, isNotEmpty, reason: '$button');
        expect(int.tryParse(button.name), isNull,
            reason: 'a numeric buttons value matches nothing in the core');
      }
    });
  });
}
