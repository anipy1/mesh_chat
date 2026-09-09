@Tags(['live'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/identity/node_identity.dart';
import 'package:mesh_chat/identity/nostr_identity.dart';
import 'package:mesh_chat/nostr/relay_client.dart';
import 'package:nostr/nostr.dart' hide Tags;

/// A real round trip through a real relay.
///
/// Skipped by default. See dart_test.yaml: a failing suite should mean our code
/// is wrong, not that a public relay happened to be down.
void main() {
  test('a gift wrapped message survives a public relay', () async {
    // A throwaway identity, so this never puts a real npub's traffic on public
    // infrastructure.
    final me = await NostrIdentity.fromSeed(NodeIdentity.newSeed());
    // The key is what lets us read gift wraps back. Relays that carry private
    // messages require NIP-42 before serving them, which is the correct call:
    // otherwise anyone could subscribe to kind 1059 by recipient and learn who
    // is receiving messages, which is most of what the encryption was hiding.
    final client = RelayClient(
      Uri.parse('wss://nos.lol'),
      secretKey: me.privateKeyHex,
    );
    addTearDown(client.close);

    final notices = <String>[];
    client.notices.listen(notices.add);

    final inbox = Completer<Event>();
    client.events.listen((event) {
      if (event.kind == 1059 && !inbox.isCompleted) inbox.complete(event);
    });

    client.open();
    client.subscribe([
      Filter(kinds: const [1059], pTags: [me.publicKeyHex], limit: 10),
    ]);

    // Give the subscription a moment to land before publishing into it.
    await Future<void>.delayed(const Duration(seconds: 2));

    const secret = 'the mesh reached the internet';
    final wrap = await DirectMessage.create(
      message: secret,
      authorSecretKey: me.privateKeyHex,
      recipientPubkey: me.publicKeyHex,
    );

    // A gift wrap is kind 1059 and its author is an ephemeral key, not ours.
    // That is the point of NIP-59: the relay cannot see who is talking.
    expect(wrap.kind, 1059);
    expect(wrap.pubkey, isNot(me.publicKeyHex));

    final verdict = client.results.firstWhere((r) => r.eventId == wrap.id);
    client.publish(wrap);

    final result = await verdict.timeout(const Duration(seconds: 20));
    expect(
      result.accepted,
      isTrue,
      reason: 'relay rejected it: ${result.message}, notices: $notices',
    );

    final received = await inbox.future.timeout(const Duration(seconds: 25));
    final opened = await DirectMessage.parse(
      giftWrap: received,
      recipientSecretKey: me.privateKeyHex,
    );

    expect(opened.kind, 14);
    expect(opened.content, secret);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
