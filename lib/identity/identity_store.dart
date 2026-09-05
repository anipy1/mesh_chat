import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'node_identity.dart';

/// How an identity was obtained, so the caller can say so out loud.
enum IdentitySource {
  /// Read back from storage. The normal case after the first run.
  restored,

  /// Nothing was stored, so a new seed was made. Expected exactly once.
  created,

  /// Something was stored but could not be read as a seed, so a new one was
  /// made.
  ///
  /// This is a silent change of who this node is, which is the worst thing
  /// that can happen to an identity, so it is reported separately rather than
  /// folded in with [created].
  replaced,
}

class LoadedIdentity {
  const LoadedIdentity(this.identity, this.source);

  final NodeIdentity identity;
  final IdentitySource source;
}

/// Where the seed lives.
///
/// A seam rather than a direct dependency on the storage plugin, for two
/// reasons. The plugin's method signatures move between major versions, and
/// faking those in a test pins us to whichever one we happened to write
/// against. And the logic worth testing here is what happens to a missing or
/// unreadable seed, which has nothing to do with any keystore.
abstract class SeedVault {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> delete();
}

/// The real one: Keychain on darwin, and on Android a hardware-backed key
/// wrapping the value.
class SecureSeedVault implements SeedVault {
  const SecureSeedVault();

  /// Versioned so a future change to what is stored can be told apart from a
  /// corrupt value rather than guessed at.
  static const key = 'mesh_chat.identity.seed.v1';

  /// Readable once the device has been unlocked at least once since boot,
  /// including while it is locked afterwards.
  ///
  /// The default is stricter, readable only while unlocked, which would stop
  /// the mesh dead the moment the screen locks. That is precisely when a mesh
  /// app should still be working.
  static const _darwin = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: key, iOptions: _darwin);

  @override
  Future<void> write(String value) =>
      _storage.write(key: key, value: value, iOptions: _darwin);

  @override
  Future<void> delete() => _storage.delete(key: key, iOptions: _darwin);
}

/// Loads this node's identity, making one the first time.
///
/// Only the seed is stored. Every key is derived on load, which costs a few
/// milliseconds once per launch and means there is one secret on disk rather
/// than four copies of the same secret in different shapes.
class IdentityStore {
  const IdentityStore({SeedVault vault = const SecureSeedVault()})
      : _vault = vault;

  final SeedVault _vault;

  Future<LoadedIdentity> loadOrCreate() async {
    final stored = await _vault.read();

    if (stored != null) {
      final seed = _decodeSeed(stored);
      if (seed != null) {
        return LoadedIdentity(
          await NodeIdentity.fromSeed(seed),
          IdentitySource.restored,
        );
      }
      // Nothing can be recovered from an unreadable seed, and there is no
      // server to ask, so the only way forward is a new identity. The caller is
      // told, because to everyone else on the mesh this node just turned into
      // a stranger.
      return LoadedIdentity(await _create(), IdentitySource.replaced);
    }

    return LoadedIdentity(await _create(), IdentitySource.created);
  }

  Future<NodeIdentity> _create() async {
    final seed = NodeIdentity.newSeed();
    await _vault.write(_encodeSeed(seed));
    return NodeIdentity.fromSeed(seed);
  }

  /// Forgets this node completely. There is no undo without the seed.
  Future<void> erase() => _vault.delete();

  static String _encodeSeed(Uint8List seed) {
    final out = StringBuffer();
    for (final b in seed) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// Returns null for anything that is not exactly a seed, rather than
  /// throwing or half-parsing. A short read, a truncated write and a value
  /// written by some future version all land here and all mean the same thing.
  static Uint8List? _decodeSeed(String value) {
    if (value.length != NodeIdentity.seedLength * 2) return null;
    final out = Uint8List(NodeIdentity.seedLength);
    for (var i = 0; i < NodeIdentity.seedLength; i++) {
      final byte = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }
}
