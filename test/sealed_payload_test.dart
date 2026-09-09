import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/ble/sealed_payload.dart';

void main() {
  const pubkey =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  group('text', () {
    test('round trips', () {
      final parsed = SealedPayload.parse(
        SealedPayload.encodeText('hello there'),
      )!;
      expect(parsed.kind, SealedKind.text);
      expect(parsed.text, 'hello there');
    });

    test('survives characters outside ascii', () {
      final parsed = SealedPayload.parse(
        SealedPayload.encodeText('नमस्ते 🙏'),
      )!;
      expect(parsed.text, 'नमस्ते 🙏');
    });

    test('an empty message is still a message', () {
      final parsed = SealedPayload.parse(SealedPayload.encodeText(''))!;
      expect(parsed.kind, SealedKind.text);
      expect(parsed.text, '');
    });
  });

  group('nostr address', () {
    test('round trips as hex', () {
      final parsed = SealedPayload.parse(
        SealedPayload.encodeNostrAddress(pubkey),
      )!;
      expect(parsed.kind, SealedKind.nostrAddress);
      expect(parsed.hex, pubkey);
    });

    test('is exactly 33 bytes on the wire', () {
      // One byte of kind and a 32 byte key. Worth pinning: this rides inside
      // every session and the frame budget is small.
      expect(SealedPayload.encodeNostrAddress(pubkey).length, 33);
    });

    test('refuses a key that is not 64 hex characters', () {
      expect(
        () => SealedPayload.encodeNostrAddress('abc'),
        throwsArgumentError,
      );
      expect(
        () => SealedPayload.encodeNostrAddress('z' * 64),
        throwsArgumentError,
      );
    });

    test('a key of the wrong length is refused on the way in too', () {
      // Addressing internet traffic at something that is not a key would send
      // it nowhere, quietly.
      final short = Uint8List.fromList([
        SealedKind.nostrAddress.code,
        ...List.filled(20, 1),
      ]);
      expect(SealedPayload.parse(short), isNull);

      final long = Uint8List.fromList([
        SealedKind.nostrAddress.code,
        ...List.filled(40, 1),
      ]);
      expect(SealedPayload.parse(long), isNull);
    });
  });

  group('refusing what we do not understand', () {
    test('an unknown kind is skipped, not rendered', () {
      // A peer on a newer build should not turn into visible nonsense here,
      // the same rule the outer frame follows.
      expect(SealedPayload.parse([99, 1, 2, 3]), isNull);
    });

    test('nothing at all is nothing', () {
      expect(SealedPayload.parse(const []), isNull);
    });

    test('the two kinds do not collide', () {
      final text = SealedPayload.encodeText('x');
      final address = SealedPayload.encodeNostrAddress(pubkey);
      expect(text[0], isNot(address[0]));
      expect(SealedPayload.parse(text)!.kind, SealedKind.text);
      expect(SealedPayload.parse(address)!.kind, SealedKind.nostrAddress);
    });
  });
}
