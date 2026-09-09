import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/nostr/relay_client.dart';
import 'package:mesh_chat/nostr/relay_pool.dart';
import 'package:mesh_chat/nostr/relay_socket.dart';
import 'package:nostr/nostr.dart' hide Tags;

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

  Future<void> drop() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

void main() {
  late List<_FakeSocket> sockets;
  late RelayPool pool;

  setUp(() {
    sockets = [];
    pool = RelayPool([
      for (var i = 0; i < 3; i++)
        RelayClient(
          Uri.parse('wss://relay$i.example'),
          retryBase: const Duration(milliseconds: 1),
          retryCap: const Duration(milliseconds: 5),
          connect: (_) {
            final socket = _FakeSocket();
            sockets.add(socket);
            return socket;
          },
        ),
    ]);
  });

  tearDown(() async => pool.close());

  Event note(String content) => Event.from(
        kind: 1,
        tags: const [],
        content: content,
        secretKey: Keys.generate().secret,
      );

  group('fanning out', () {
    test('publishes to every relay', () {
      // Not "the first that works". We cannot tell which relay the recipient
      // is listening to, so the message goes to all of them.
      pool.open();
      pool.publish(note('hello'));

      expect(sockets, hasLength(3));
      for (final socket in sockets) {
        expect(socket.sent.where((s) => s.startsWith('["EVENT')), hasLength(1));
      }
    });

    test('subscribes on every relay under one id', () {
      pool.open();
      final id = pool.subscribe([
        const Filter(kinds: [1])
      ]);

      for (final socket in sockets) {
        final req = socket.sent.firstWhere((s) => s.startsWith('["REQ'));
        expect(jsonDecode(req)[1], id);
      }
    });

    test('unsubscribing reaches every relay', () {
      pool.open();
      final id = pool.subscribe([
        const Filter(kinds: [1])
      ]);
      pool.unsubscribe(id);

      for (final socket in sockets) {
        expect(socket.sent.where((s) => s.startsWith('["CLOSE')), hasLength(1));
      }
    });
  });

  group('deduping', () {
    test('the same event from three relays surfaces once', () async {
      // Unwrapping a gift wrap costs a key exchange, so doing it three times
      // for one message is worth avoiding even though the mesh would dedupe
      // the frame anyway.
      pool.open();
      final event = note('once');
      final seen = <Event>[];
      pool.events.listen(seen.add);

      for (final socket in sockets) {
        socket.deliver(jsonEncode(['EVENT', 'sub', event.toMap()]));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(seen, hasLength(1));
    });

    test('different events all surface', () async {
      pool.open();
      final seen = <Event>[];
      pool.events.listen(seen.add);

      sockets[0].deliver(jsonEncode(['EVENT', 'sub', note('a').toMap()]));
      sockets[1].deliver(jsonEncode(['EVENT', 'sub', note('b').toMap()]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(seen, hasLength(2));
    });
  });

  group('connection state', () {
    test('up while any relay is up', () async {
      pool.open();
      expect(pool.isConnected, isTrue);
      expect(pool.connectedCount, 3);

      // Two of three go away. One reachable relay is still a working path.
      await sockets[0].drop();
      await sockets[1].drop();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(pool.isConnected, isTrue);
    });

    test('reports the pool, not each relay', () async {
      // Otherwise a caller sees it flap every time one of four reconnects.
      final seen = <bool>[];
      pool.connectionChanges.listen(seen.add);
      pool.open();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // One relay dropping must not report the path as down.
      await sockets[0].drop();
      await Future<void>.delayed(const Duration(milliseconds: 2));

      expect(seen.where((up) => !up), isEmpty);
      expect(seen.where((up) => up), hasLength(1));
    });

    test('names the relay in a notice', () async {
      // "auth refused" from one of four is a very different situation from all
      // four refusing, and an unnamed notice cannot tell them apart.
      pool.open();
      final notice = pool.notices.first;
      sockets[1].deliver(jsonEncode(['NOTICE', 'slow down']));

      expect(await notice, contains('relay1.example'));
    });
  });

  group('counts', () {
    test('reports how many of how many', () {
      pool.open();
      expect(pool.relayCount, 3);
      expect(pool.connectedCount, 3);
    });
  });
}
