import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Everything this node is, derived from one 32 byte seed.
///
/// The seed is the only secret worth backing up. Every key below is derived
/// from it, so restoring the seed restores the identity, and losing it loses
/// the identity for good. There is no recovery path by design: a mesh with no
/// servers has nobody to ask.
///
/// Two keys come out of it, and they are deliberately different keys rather
/// than one key used twice:
///
///   seed --HKDF "sign"--> Ed25519  : signs things, the root identity
///   seed --HKDF "noise"-> X25519   : the static key Noise XX will authenticate
///
/// bitchat converts its Ed25519 key into an X25519 key instead, with ed2curve.
/// That works and is well trodden, but reusing one key across two algorithms is
/// something to do carefully rather than by default. Deriving two independent
/// keys from a common seed costs nothing here and avoids the question, and
/// HKDF's info string is exactly the tool for keeping them apart.
///
/// The Nostr secp256k1 key gets the same treatment when the internet transport
/// arrives. It is a third info string on the same seed, so adding it later does
/// not disturb anything derived today.
class NodeIdentity {
  const NodeIdentity._({
    required this.seed,
    required this.signingKeyPair,
    required this.noiseKeyPair,
    required this.signingPublicKey,
    required this.noisePublicKey,
    required this.fingerprint,
  });

  /// Info strings for the two derivations. Versioned, because changing one
  /// changes the resulting key, and that silently changes who a node is.
  static const _signInfo = 'mesh-chat/identity/sign/v1';
  static const _noiseInfo = 'mesh-chat/identity/noise/v1';

  static const seedLength = 32;

  /// The alphabet for the short label. No I, O, 0 or 1: this ends up in logs
  /// and on a 480x640 screen, where those four are indistinguishable.
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Characters in the short label. Four keeps the advertised name at seven
  /// bytes including the prefix, which is what fits alongside a 128 bit
  /// service uuid in one BLE advertisement.
  static const shortIdLength = 4;

  final Uint8List seed;
  final SimpleKeyPair signingKeyPair;
  final SimpleKeyPair noiseKeyPair;
  final Uint8List signingPublicKey;
  final Uint8List noisePublicKey;

  /// SHA-256 of the noise public key. The full value is what a human would
  /// compare out of band to be sure they are talking to who they think.
  final Uint8List fingerprint;

  /// Stable id for this node, 16 hex characters.
  ///
  /// The first 8 bytes of the fingerprint, the same construction bitchat uses.
  /// It is a hash of a public key rather than a random string, so it cannot be
  /// claimed by anyone who does not hold the seed.
  String get peerId => _hex(fingerprint.sublist(0, 8));

  /// The label that goes on the air and into logs.
  ///
  /// Short enough to advertise, and derived rather than random, so it survives
  /// a restart. Four characters is 20 bits, which is nowhere near collision
  /// resistant and is not meant to be: [peerId] and [fingerprint] are the
  /// identity, this is the name badge.
  String get shortId {
    final out = StringBuffer();
    var acc = 0;
    var bits = 0;
    var i = 0;
    while (out.length < shortIdLength) {
      if (bits < 5) {
        acc = (acc << 8) | fingerprint[i++];
        bits += 8;
      }
      bits -= 5;
      out.write(_alphabet[(acc >> bits) & 0x1f]);
    }
    return out.toString();
  }

  /// A fresh seed. Random.secure is the platform CSPRNG.
  ///
  /// 32 bytes is also exactly BIP39's 256 bit entropy, so this seed can be
  /// rendered as a 24 word phrase later without changing a single derived key.
  static Uint8List newSeed() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List.generate(seedLength, (_) => rnd.nextInt(256)),
    );
  }

  /// Derives the whole identity from [seed]. Deterministic: the same seed
  /// always produces the same node.
  static Future<NodeIdentity> fromSeed(Uint8List seed) async {
    if (seed.length != seedLength) {
      throw ArgumentError('seed must be $seedLength bytes, got ${seed.length}');
    }

    final signSeed = await _derive(seed, _signInfo);
    final noiseSeed = await _derive(seed, _noiseInfo);

    final signingKeyPair = await Ed25519().newKeyPairFromSeed(signSeed);
    final noiseKeyPair = await X25519().newKeyPairFromSeed(noiseSeed);

    final signingPublic = await signingKeyPair.extractPublicKey();
    final noisePublic = await noiseKeyPair.extractPublicKey();
    final noisePublicBytes = Uint8List.fromList(noisePublic.bytes);

    final digest = await Sha256().hash(noisePublicBytes);

    return NodeIdentity._(
      seed: seed,
      signingKeyPair: signingKeyPair,
      noiseKeyPair: noiseKeyPair,
      signingPublicKey: Uint8List.fromList(signingPublic.bytes),
      noisePublicKey: noisePublicBytes,
      fingerprint: Uint8List.fromList(digest.bytes),
    );
  }

  /// HKDF-SHA256 with an empty salt and a distinct info string per key.
  ///
  /// Empty salt is the standard construction when there is no salt to speak of.
  /// The separation that matters here comes from [info], which is what stops
  /// the signing key and the noise key from being related.
  static Future<List<int>> _derive(Uint8List seed, String info) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final out = await hkdf.deriveKey(
      secretKey: SecretKey(seed),
      nonce: const <int>[],
      info: info.codeUnits,
    );
    return out.extractBytes();
  }

  static String _hex(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// The fingerprint in the form a human can read back over a phone call.
  String get readableFingerprint {
    final hex = _hex(fingerprint);
    final groups = <String>[];
    for (var i = 0; i < hex.length; i += 8) {
      groups.add(hex.substring(i, i + 8));
    }
    return groups.join(' ');
  }

  @override
  String toString() => 'NodeIdentity($shortId, $peerId)';
}
