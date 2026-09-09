@Tags(['live'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/identity/node_identity.dart';
import 'package:mesh_chat/identity/nostr_identity.dart';
import 'package:mesh_chat/nostr/nostr_bridge.dart';
import 'package:mesh_chat/nostr/relay_pool.dart';

/// Two nodes with no radio between them, talking through a real relay.
///
/// Skipped by default; see dart_test.yaml.
void main() {
  test('a frame crosses the internet between two nodes', () async {
    // The same four the app uses, each checked to carry a gift wrap both ways.
    final relays = [
      Uri.parse('wss://nos.lol'),
      Uri.parse('wss://relay.primal.net'),
      Uri.parse('wss://nostr.mom'),
      Uri.parse('wss://offchain.pub'),
    ];

    final alice = await NostrIdentity.fromSeed(NodeIdentity.newSeed());
    final bob = await NostrIdentity.fromSeed(NodeIdentity.newSeed());

    final aliceBridge = NostrBridge(
      identity: alice,
      client: RelayPool.forUrls(relays, secretKey: alice.privateKeyHex),
    );
    final bobBridge = NostrBridge(
      identity: bob,
      client: RelayPool.forUrls(relays, secretKey: bob.privateKeyHex),
    );
    addTearDown(aliceBridge.close);
    addTearDown(bobBridge.close);

    final received = <Uint8List>[];
    bobBridge.inbound.listen(received.add);

    aliceBridge.start();
    bobBridge.start();

    // Let both subscriptions land before anything is published into them.
    await Future<void>.delayed(const Duration(seconds: 3));

    // Stand-in for a sealed frame: opaque bytes the bridge must not touch.
    final frame = Uint8List.fromList([
      for (var i = 0; i < 200; i++) (i * 7 + 13) % 256,
    ]);

    expect(await aliceBridge.send(bob.publicKeyHex, frame), isTrue);

    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (received.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    expect(received, isNotEmpty, reason: 'nothing arrived through the pool');
    // Four relays, one delivery. The pool dedupes by event id so a gift wrap
    // is not unwrapped four times, and unwrapping costs a key exchange.
    expect(received, hasLength(1));
    // Byte for byte. Anything else means the bridge is not transparent, and a
    // sealed frame that changed in transit would simply fail to open.
    expect(received.first, frame);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
