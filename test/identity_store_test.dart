import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/identity/identity_store.dart';
import 'package:mesh_chat/identity/node_identity.dart';

/// An in-memory vault, which is all the store needs to be exercised.
class _MemoryVault implements SeedVault {
  _MemoryVault([this.value]);

  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async {
    value = v;
    writes++;
  }

  @override
  Future<void> delete() async => value = null;
}

void main() {
  group('first run', () {
    test('makes an identity and stores the seed', () async {
      final vault = _MemoryVault();
      final loaded = await IdentityStore(vault: vault).loadOrCreate();

      expect(loaded.source, IdentitySource.created);
      expect(vault.writes, 1);
      expect(vault.value, isNotNull);
      expect(vault.value!.length, NodeIdentity.seedLength * 2);
    });
  });

  group('later runs', () {
    test('the identity survives a restart', () async {
      // The whole point. Before this, every launch was a different node.
      final vault = _MemoryVault();
      final first = await IdentityStore(vault: vault).loadOrCreate();
      final second = await IdentityStore(vault: vault).loadOrCreate();

      expect(second.source, IdentitySource.restored);
      expect(second.identity.peerId, first.identity.peerId);
      expect(second.identity.shortId, first.identity.shortId);
      expect(second.identity.noisePublicKey, first.identity.noisePublicKey);
    });

    test('restoring does not rewrite the seed', () async {
      final vault = _MemoryVault();
      await IdentityStore(vault: vault).loadOrCreate();
      await IdentityStore(vault: vault).loadOrCreate();
      expect(vault.writes, 1);
    });

    test('two nodes with their own vaults are different nodes', () async {
      final a = await IdentityStore(vault: _MemoryVault()).loadOrCreate();
      final b = await IdentityStore(vault: _MemoryVault()).loadOrCreate();
      expect(a.identity.peerId, isNot(b.identity.peerId));
    });
  });

  group('a stored value that is not a seed', () {
    // Losing the seed means losing the identity, and there is no server to ask
    // for it back. All the store can do is be loud about it.
    for (final bad in <String>{
      '',
      'not hex at all',
      'ab',
      'zz' * NodeIdentity.seedLength,
      'ab' * (NodeIdentity.seedLength - 1),
      'ab' * (NodeIdentity.seedLength + 1),
    }) {
      test('is replaced and reported: "${bad.length} chars"', () async {
        final vault = _MemoryVault(bad);
        final loaded = await IdentityStore(vault: vault).loadOrCreate();

        expect(loaded.source, IdentitySource.replaced);
        expect(vault.value, isNot(bad));
        expect(vault.value!.length, NodeIdentity.seedLength * 2);
      });
    }

    test('the replacement is itself stable afterwards', () async {
      final vault = _MemoryVault('garbage');
      final first = await IdentityStore(vault: vault).loadOrCreate();
      final second = await IdentityStore(vault: vault).loadOrCreate();

      expect(first.source, IdentitySource.replaced);
      expect(second.source, IdentitySource.restored);
      expect(second.identity.peerId, first.identity.peerId);
    });
  });

  group('erase', () {
    test('forgetting the seed means a different node next time', () async {
      final vault = _MemoryVault();
      final store = IdentityStore(vault: vault);
      final before = await store.loadOrCreate();

      await store.erase();
      final after = await store.loadOrCreate();

      expect(after.source, IdentitySource.created);
      expect(after.identity.peerId, isNot(before.identity.peerId));
    });
  });
}
