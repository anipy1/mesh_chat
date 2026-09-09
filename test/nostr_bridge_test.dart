import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/identity/node_identity.dart';
import 'package:mesh_chat/identity/nostr_identity.dart';
import 'package:mesh_chat/nostr/nostr_bridge.dart';
import 'package:mesh_chat/nostr/relay_client.dart';
import 'package:mesh_chat/nostr/relay_socket.dart';
import 'package:nostr/nostr.dart' hide Tags;

/// A relay we control.
class _FakeSocket implements RelaySocket {
  final _incoming = StreamController<String>();
  final sent = <String>[];

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  void deliver(String payload) => _incoming.add(payload);
}

void main() {
  late _FakeSocket socket;
  late NostrIdentity me;
  late NostrBridge bridge;

  setUp(() async {
    socket = _FakeSocket();
    me = await NostrIdentity.fromSeed(NodeIdentity.newSeed());
    bridge = NostrBridge(
      identity: me,
      client: RelayClient(
        Uri.parse('wss://relay.example'),
        connect: (_) => socket,
        secretKey: me.privateKeyHex,
      ),
    );
  });

  tearDown(() async => bridge.close());

  group('subscribing', () {
    test('asks only for gift wraps addressed to us', () {
      bridge.start();
      final decoded = jsonDecode(socket.sent.single) as List<dynamic>;
      expect(decoded[0], 'REQ');
      final filter = decoded[2] as Map<String, dynamic>;
      expect(filter['kinds'], [1059]);
      expect(filter['#p'], [me.publicKeyHex]);
    });

    test('reaches back far enough for a randomised gift wrap timestamp', () {
      // NIP-59 randomises created_at into the past, by up to two days, so that
      // timestamps cannot be correlated. A since of "now" silently filters out
      // messages sent seconds ago.
      bridge.start();
      final decoded = jsonDecode(socket.sent.single) as List<dynamic>;
      final filter = decoded[2] as Map<String, dynamic>;
      final since = filter['since'] as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(now - since, greaterThanOrEqualTo(2 * 24 * 60 * 60 - 5));
    });
  });

  group('sending', () {
    test('publishes a gift wrap, not the frame itself', () async {
      bridge.start();
      socket.sent.clear();

      final frame = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(await bridge.send(me.publicKeyHex, frame), isTrue);

      final decoded = jsonDecode(socket.sent.single) as List<dynamic>;
      expect(decoded[0], 'EVENT');
      final event = decoded[1] as Map<String, dynamic>;
      expect(event['kind'], 1059);
      // The relay must not see who is really sending. A gift wrap is authored
      // by an ephemeral key, never ours.
      expect(event['pubkey'], isNot(me.publicKeyHex));
      // And the frame must not be readable in the content.
      expect(event['content'], isNot(contains(base64Encode(frame))));
    });

    test('reports failure rather than throwing when there is no relay',
        () async {
      // An unreachable relay is ordinary here, and the caller has an outbox.
      final frame = Uint8List.fromList([9]);
      expect(await bridge.send(me.publicKeyHex, frame), isFalse);
    });
  });

  group('receiving', () {
    test('recovers the exact frame bytes', () async {
      bridge.start();
      final frame = Uint8List.fromList([0, 255, 12, 200, 7, 7, 7]);

      // Somebody else sends to us.
      final sender = await NostrIdentity.fromSeed(NodeIdentity.newSeed());
      final wrap = await DirectMessage.create(
        message: base64Encode(frame),
        authorSecretKey: sender.privateKeyHex,
        recipientPubkey: me.publicKeyHex,
      );

      final received = bridge.inbound.first;
      socket.deliver(jsonEncode(['EVENT', 'sub', wrap.toMap()]));

      expect(await received, frame);
    });

    test('a wrap we cannot open is ignored, not fatal', () async {
      // Relays deliver whatever matches the filter, including things sealed to
      // keys we no longer hold.
      bridge.start();
      final other = await NostrIdentity.fromSeed(NodeIdentity.newSeed());
      final stranger = await NostrIdentity.fromSeed(NodeIdentity.newSeed());
      final notForUs = await DirectMessage.create(
        message: base64Encode(Uint8List.fromList([1])),
        authorSecretKey: stranger.privateKeyHex,
        recipientPubkey: other.publicKeyHex,
      );

      var got = 0;
      bridge.inbound.listen((_) => got++);
      socket.deliver(jsonEncode(['EVENT', 'sub', notForUs.toMap()]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(got, 0);
      expect(bridge.isConnected, isTrue);
    });

    test('content that is not a frame is ignored', () async {
      bridge.start();
      final sender = await NostrIdentity.fromSeed(NodeIdentity.newSeed());
      final wrap = await DirectMessage.create(
        message: 'not base64 !!!',
        authorSecretKey: sender.privateKeyHex,
        recipientPubkey: me.publicKeyHex,
      );

      var got = 0;
      bridge.inbound.listen((_) => got++);
      socket.deliver(jsonEncode(['EVENT', 'sub', wrap.toMap()]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(got, 0);
    });

    test('other kinds are ignored', () async {
      bridge.start();
      final keys = Keys.generate();
      final note = Event.from(
        kind: 1,
        tags: const [],
        content: 'a public note',
        secretKey: keys.secret,
      );

      var got = 0;
      bridge.inbound.listen((_) => got++);
      socket.deliver(jsonEncode(['EVENT', 'sub', note.toMap()]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(got, 0);
    });
  });
}
