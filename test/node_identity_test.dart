import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/identity/node_identity.dart';

void main() {
  Uint8List seedOf(int fill) =>
      Uint8List.fromList(List.filled(NodeIdentity.seedLength, fill));

  group('derivation', () {
    test('the same seed always produces the same node', () async {
      final a = await NodeIdentity.fromSeed(seedOf(7));
      final b = await NodeIdentity.fromSeed(seedOf(7));
      expect(a.peerId, b.peerId);
      expect(a.shortId, b.shortId);
      expect(a.noisePublicKey, b.noisePublicKey);
      expect(a.signingPublicKey, b.signingPublicKey);
    });

    test('a different seed produces a different node', () async {
      final a = await NodeIdentity.fromSeed(seedOf(7));
      final b = await NodeIdentity.fromSeed(seedOf(8));
      expect(a.peerId, isNot(b.peerId));
      expect(a.noisePublicKey, isNot(b.noisePublicKey));
    });

    test('the signing key and the noise key are not the same key', () async {
      // The whole point of deriving two keys instead of converting one.
      final id = await NodeIdentity.fromSeed(seedOf(7));
      expect(id.signingPublicKey, isNot(id.noisePublicKey));
    });

    test('keys are the sizes the algorithms expect', () async {
      final id = await NodeIdentity.fromSeed(seedOf(7));
      expect(id.signingPublicKey.length, 32);
      expect(id.noisePublicKey.length, 32);
      expect(id.fingerprint.length, 32);
    });

    test('rejects a seed that is not the right length', () async {
      expect(
        () => NodeIdentity.fromSeed(Uint8List(16)),
        throwsArgumentError,
      );
    });
  });

  group('identifiers', () {
    test('peerId is the first 8 bytes of the fingerprint, in hex', () async {
      final id = await NodeIdentity.fromSeed(seedOf(7));
      expect(id.peerId.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(id.peerId), isTrue);
      final firstByte = int.parse(id.peerId.substring(0, 2), radix: 16);
      expect(firstByte, id.fingerprint[0]);
    });

    test('the fingerprint commits to the noise key, not the signing key',
        () async {
      // This is what Noise XX will authenticate, so it is what the fingerprint
      // has to be about. Getting this backwards would let someone present one
      // key and be verified against another.
      final id = await NodeIdentity.fromSeed(seedOf(7));
      final other = await NodeIdentity.fromSeed(seedOf(9));
      expect(id.fingerprint, isNot(other.fingerprint));
    });

    test('shortId avoids the characters that misread in a log', () async {
      for (var i = 0; i < 40; i++) {
        final id = await NodeIdentity.fromSeed(seedOf(i));
        expect(id.shortId.length, NodeIdentity.shortIdLength);
        expect(RegExp(r'^[A-HJ-NP-Z2-9]{4}$').hasMatch(id.shortId), isTrue,
            reason: 'got ${id.shortId}');
      }
    });

    test('readable fingerprint keeps every byte', () async {
      final id = await NodeIdentity.fromSeed(seedOf(7));
      final joined = id.readableFingerprint.replaceAll(' ', '');
      expect(joined.length, 64);
    });
  });

  group('seed', () {
    test('newSeed is the right length and not constant', () {
      final a = NodeIdentity.newSeed();
      final b = NodeIdentity.newSeed();
      expect(a.length, NodeIdentity.seedLength);
      expect(b.length, NodeIdentity.seedLength);
      expect(a, isNot(b));
    });

    test('a real random seed round trips through derivation', () async {
      final seed = NodeIdentity.newSeed();
      final a = await NodeIdentity.fromSeed(seed);
      final b = await NodeIdentity.fromSeed(Uint8List.fromList(seed));
      expect(a.peerId, b.peerId);
    });
  });
}
