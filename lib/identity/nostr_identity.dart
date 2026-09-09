import 'dart:typed_data';

import 'package:nostr/nostr.dart';

import 'node_identity.dart';

/// This node's Nostr identity, derived from the same seed as everything else.
///
/// Kept apart from [NodeIdentity] on purpose, in its own file with its own
/// dependency. The mesh has to work with no internet at all, and nothing on the
/// BLE path should need the Nostr package to compile or run. This is only
/// reached for when there is a relay to talk to.
///
/// Nostr is secp256k1 and Noise is X25519, which is why this cannot simply
/// reuse the mesh key. Two curves, two keys, one seed:
///
///   seed --HKDF "sign"--> Ed25519    : signs things on the mesh
///   seed --HKDF "noise"-> X25519     : the static key Noise XX authenticates
///   seed --HKDF "nostr"-> secp256k1  : this, for the internet transport
///
/// Because it comes from the seed, restoring the seed restores the npub too.
/// There is no separate Nostr backup to lose, and adding this changed nothing
/// about the two keys derived before it: the info strings keep them apart.
class NostrIdentity {
  const NostrIdentity._({
    required this.keys,
    required this.privateKeyHex,
    required this.publicKeyHex,
    required this.npub,
    required this.nsec,
  });

  /// Versioned like the others. Changing it changes the npub, which to anyone
  /// following this identity means it became a different person.
  static const info = 'mesh-chat/identity/nostr/v1';

  /// The order of the secp256k1 group. A private key must be in [1, n-1].
  static final BigInt _order = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
    radix: 16,
  );

  final Keys keys;
  final String privateKeyHex;

  /// The 32 byte x-only public key, as Nostr uses it.
  final String publicKeyHex;

  final String npub;
  final String nsec;

  static Future<NostrIdentity> fromSeed(Uint8List seed) async {
    final scalar = await _deriveScalar(seed);
    final hex = _hex(scalar);
    final keys = Keys(hex);
    return NostrIdentity._(
      keys: keys,
      privateKeyHex: keys.secret,
      publicKeyHex: keys.public,
      npub: keys.npub,
      nsec: keys.nsec,
    );
  }

  /// Derives a scalar that is actually a valid secp256k1 private key.
  ///
  /// HKDF returns 32 uniform bytes, which is a valid key with probability so
  /// close to one that the failing case will never be seen: the gap above the
  /// group order is about one in 2^128, and zero is one in 2^256. It is checked
  /// anyway, and a rejected value re-derives under a counter rather than being
  /// clamped or reduced. Reducing mod n would bias the result, and while the
  /// bias here would be unmeasurable, "unmeasurable bias in key generation" is
  /// not a sentence worth having in a codebase.
  static Future<Uint8List> _deriveScalar(Uint8List seed) async {
    for (var counter = 0; counter < 256; counter++) {
      final label = counter == 0 ? info : '$info/$counter';
      final bytes = Uint8List.fromList(
        await NodeIdentity.deriveKeyMaterial(seed, label),
      );
      final value = BigInt.parse(_hex(bytes), radix: 16);
      if (value > BigInt.zero && value < _order) return bytes;
    }
    // Unreachable short of a broken HKDF, and better than returning something
    // invalid.
    throw StateError('no valid secp256k1 scalar after 256 attempts');
  }

  static String _hex(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// The npub in the form worth showing a human, shortened at both ends.
  ///
  /// A full npub is 63 characters and unreadable on a phone. The middle is
  /// dropped rather than the tail, because both ends have to match for a
  /// comparison to mean anything.
  String get shortNpub => npub.length <= 20
      ? npub
      : '${npub.substring(0, 10)}...'
          '${npub.substring(npub.length - 6)}';

  @override
  String toString() => 'NostrIdentity($shortNpub)';
}
