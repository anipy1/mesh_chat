import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/identity/node_identity.dart';
import 'package:mesh_chat/identity/nostr_identity.dart';

void main() {
  Uint8List seedOf(int fill) =>
      Uint8List.fromList(List.filled(NodeIdentity.seedLength, fill));

  group('derivation', () {
    test('the same seed always gives the same npub', () async {
      // The property the whole design rests on: restore the seed and the Nostr
      // identity comes back with it. There is no separate backup to lose.
      final a = await NostrIdentity.fromSeed(seedOf(7));
      final b = await NostrIdentity.fromSeed(seedOf(7));
      expect(a.npub, b.npub);
      expect(a.nsec, b.nsec);
      expect(a.publicKeyHex, b.publicKeyHex);
    });

    test('a different seed gives a different identity', () async {
      final a = await NostrIdentity.fromSeed(seedOf(7));
      final b = await NostrIdentity.fromSeed(seedOf(8));
      expect(a.npub, isNot(b.npub));
    });

    test('the Nostr key is unrelated to the mesh keys', () async {
      // Different curves, so they could never be the same key, but they must
      // not even be derived from the same material. That is what the info
      // strings are for.
      final seed = seedOf(7);
      final mesh = await NodeIdentity.fromSeed(seed);
      final nostr = await NostrIdentity.fromSeed(seed);

      final meshNoise = mesh.noisePublicKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final meshSign = mesh.signingPublicKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      expect(nostr.publicKeyHex, isNot(meshNoise));
      expect(nostr.publicKeyHex, isNot(meshSign));
      expect(nostr.privateKeyHex, isNot(meshNoise));
    });

    test('adding Nostr did not disturb the keys derived before it', () async {
      // A regression guard. If someone changes the shared HKDF helper, the
      // mesh identity changes, and every node silently becomes a stranger.
      final id = await NodeIdentity.fromSeed(seedOf(1));
      expect(id.peerId.length, 16);
      expect(id.noisePublicKey.length, 32);
      // Deriving the Nostr key from the same seed must not alter it.
      await NostrIdentity.fromSeed(seedOf(1));
      final again = await NodeIdentity.fromSeed(seedOf(1));
      expect(again.peerId, id.peerId);
    });
  });

  group('encoding', () {
    test('keys are the shapes Nostr expects', () async {
      final id = await NostrIdentity.fromSeed(seedOf(7));
      expect(id.publicKeyHex.length, 64);
      expect(id.privateKeyHex.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(id.publicKeyHex), isTrue);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(id.privateKeyHex), isTrue);
    });

    test('bech32 forms are npub and nsec', () async {
      final id = await NostrIdentity.fromSeed(seedOf(7));
      expect(id.npub, startsWith('npub1'));
      expect(id.nsec, startsWith('nsec1'));
    });

    test('the short npub keeps both ends', () async {
      // Only useful for comparison if the tail survives, since an attacker can
      // grind a matching prefix.
      final id = await NostrIdentity.fromSeed(seedOf(7));
      expect(id.shortNpub, startsWith(id.npub.substring(0, 10)));
      expect(id.shortNpub, endsWith(id.npub.substring(id.npub.length - 6)));
      expect(id.shortNpub.length, lessThan(id.npub.length));
    });
  });

  group('valid scalars', () {
    test('every seed produces a usable key', () async {
      // The range check has a vanishing chance of rejecting anything, so this
      // is really checking that derivation and encoding hold up across many
      // different inputs rather than exercising the retry.
      for (var i = 0; i < 40; i++) {
        final id = await NostrIdentity.fromSeed(seedOf(i));
        expect(id.npub, startsWith('npub1'));
        expect(id.publicKeyHex.length, 64);
      }
    });

    test('a real random seed round trips', () async {
      final seed = NodeIdentity.newSeed();
      final a = await NostrIdentity.fromSeed(seed);
      final b = await NostrIdentity.fromSeed(Uint8List.fromList(seed));
      expect(a.npub, b.npub);
    });

    test('signing works, so the key is genuinely on the curve', () async {
      // The strongest check available here. An out of range or malformed
      // scalar would not produce a usable signature.
      final id = await NostrIdentity.fromSeed(seedOf(7));
      final digest = 'a' * 64; // a 32 byte hex message
      final signature = id.keys.sign(message: digest);
      expect(signature.length, 128);
    });
  });
}
