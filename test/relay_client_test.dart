import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/nostr/relay_client.dart';
import 'package:mesh_chat/nostr/relay_socket.dart';
import 'package:nostr/nostr.dart';

/// A relay we control completely.
class _FakeSocket implements RelaySocket {
  _FakeSocket();

  final _incoming = StreamController<String>();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// The relay says something.
  void deliver(String payload) => _incoming.add(payload);

  /// The relay hangs up, the way public ones do.
  Future<void> drop() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

void main() {
  late List<_FakeSocket> sockets;
  late RelayClient client;

  setUp(() {
    sockets = [];
    client = RelayClient(
      Uri.parse('wss://relay.example'),
      retryBase: const Duration(milliseconds: 1),
      retryCap: const Duration(milliseconds: 5),
      connect: (_) {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
    );
  });

  tearDown(() async => client.close());

  _FakeSocket current() => sockets.last;

  group('subscribing', () {
    test('sends a REQ and reports the id', () {
      client.open();
      final id = client.subscribe([
        const Filter(kinds: [1], limit: 5)
      ]);

      expect(current().sent, hasLength(1));
      final decoded = jsonDecode(current().sent.single) as List<dynamic>;
      expect(decoded[0], 'REQ');
      expect(decoded[1], id);
    });

    test('a subscription asked for before connecting still goes out', () {
      // The app should not have to care whether the socket is up yet.
      final id = client.subscribe([
        const Filter(kinds: [1])
      ]);
      expect(sockets, isEmpty);

      client.open();
      final decoded = jsonDecode(current().sent.single) as List<dynamic>;
      expect(decoded[1], id);
    });

    test('unsubscribing sends CLOSE and stops restoring it', () async {
      client.open();
      final id = client.subscribe([
        const Filter(kinds: [1])
      ]);
      client.unsubscribe(id);

      expect(current().sent.last, contains('CLOSE'));

      await current().drop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // The new socket must not carry the cancelled subscription.
      expect(sockets.length, greaterThan(1));
      expect(current().sent.where((s) => s.contains(id)), isEmpty);
    });
  });

  group('reconnecting', () {
    test('a dropped relay is reconnected', () async {
      client.open();
      expect(sockets, hasLength(1));

      await current().drop();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(sockets.length, greaterThan(1));
      expect(client.isConnected, isTrue);
    });

    test('subscriptions are restored after a drop', () async {
      // A relay remembers nothing across connections. Without this the app
      // would sit waiting for messages it never actually asked for.
      client.open();
      final id = client.subscribe([
        const Filter(kinds: [1])
      ]);

      await current().drop();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final decoded = jsonDecode(current().sent.first) as List<dynamic>;
      expect(decoded[0], 'REQ');
      expect(decoded[1], id);
    });

    test('connection changes are reported', () async {
      final seen = <bool>[];
      client.connectionChanges.listen(seen.add);
      client.open();
      await Future<void>.delayed(Duration.zero);
      await current().drop();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(seen.first, isTrue);
      expect(seen, contains(false));
    });
  });

  group('incoming messages', () {
    test('an EVENT reaches the events stream', () async {
      client.open();
      final keys = Keys.generate();
      final event = Event.from(
        kind: 1,
        tags: const [],
        content: 'hello',
        secretKey: keys.secret,
      );

      final received = client.events.first;
      current().deliver(jsonEncode(['EVENT', 'sub1', event.toMap()]));

      expect((await received).content, 'hello');
    });

    test('an OK becomes a publish result', () async {
      client.open();
      final received = client.results.first;
      current().deliver(jsonEncode(['OK', 'abc123', true, 'stored']));

      final result = await received;
      expect(result.eventId, 'abc123');
      expect(result.accepted, isTrue);
      expect(result.message, 'stored');
    });

    test('a rejection is reported as one, not as an error', () async {
      // Relays refuse events routinely, for rate limits or policy. That is
      // information, not a failure of the connection.
      client.open();
      final received = client.results.first;
      current().deliver(
        jsonEncode(['OK', 'abc123', false, 'rate-limited: slow down']),
      );

      final result = await received;
      expect(result.accepted, isFalse);
      expect(result.message, contains('rate-limited'));
      expect(client.isConnected, isTrue);
    });

    test('a NOTICE reaches the notices stream', () async {
      client.open();
      final received = client.notices.first;
      current().deliver(jsonEncode(['NOTICE', 'be nice']));
      expect(await received, contains('be nice'));
    });

    test('CLOSED stops the subscription being restored', () async {
      client.open();
      final id = client.subscribe([
        const Filter(kinds: [1])
      ]);
      current().deliver(jsonEncode(['CLOSED', id, 'unsupported filter']));
      await Future<void>.delayed(Duration.zero);

      await current().drop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(current().sent.where((s) => s.contains(id)), isEmpty);
    });

    test('rubbish does not take the connection down', () async {
      // Relays send NIPs we do not implement, and occasionally malformed
      // frames. Dropping a working connection over that would be worse.
      client.open();
      current().deliver('not json at all');
      current().deliver(jsonEncode(['WAT', 'unknown message type']));
      current().deliver('{}');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(client.isConnected, isTrue);
      expect(sockets, hasLength(1));
    });
  });

  group('publishing', () {
    test('serialises the event onto the socket', () {
      client.open();
      final keys = Keys.generate();
      final event = Event.from(
        kind: 1,
        tags: const [],
        content: 'published',
        secretKey: keys.secret,
      );
      client.publish(event);

      final decoded = jsonDecode(current().sent.single) as List<dynamic>;
      expect(decoded[0], 'EVENT');
      expect((decoded[1] as Map)['content'], 'published');
    });

    test('publishing while disconnected is dropped, not thrown', () {
      // There is no queue here on purpose. A message that matters goes in the
      // outbox; this is the transport, and it should not pretend to be one.
      final keys = Keys.generate();
      final event = Event.from(
        kind: 1,
        tags: const [],
        content: 'nowhere',
        secretKey: keys.secret,
      );
      expect(() => client.publish(event), returnsNormally);
    });
  });

  group('closing', () {
    test('closes the socket and stops reconnecting', () async {
      client.open();
      final socket = current();
      await client.close();

      expect(socket.closed, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sockets, hasLength(1));
    });

    test('opening a closed client is refused', () async {
      client.open();
      await client.close();
      expect(client.open, throwsStateError);
    });
  });
}
