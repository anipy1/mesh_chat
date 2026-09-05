import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/noise/noise_protocol.dart';
import 'package:mesh_chat/noise/session_manager.dart';

/// One handshake step in flight, so a test can decide when it is delivered.
class _Step {
  _Step(this.from, this.to, this.step, this.body);

  final String from;
  final String to;
  final int step;
  final Uint8List body;
}

/// Two managers and the wire between them, held rather than delivered.
///
/// Nothing here is automatic. The whole reason this layer exists is the cases
/// where steps cross, arrive late, or never arrive at all, and none of those can
/// be written if delivery happens on its own.
class _Wire {
  final steps = <_Step>[];
  final established = <String, List<String>>{};
  final failures = <String, List<SessionFailure>>{};
  late final Map<String, SessionManager> nodes;

  Future<void> deliverAll() async {
    while (steps.isNotEmpty) {
      final next = steps.removeAt(0);
      await nodes[next.to]!.handleStep(next.from, next.step, next.body);
    }
  }
}

// ignore: library_private_types_in_public_api
Future<_Wire> twoNodes({DateTime Function()? clock}) async {
  final wire = _Wire();
  final keyA = await X25519().newKeyPair();
  final keyB = await X25519().newKeyPair();
  final idA = await SessionManager.peerIdFor(
    (await keyA.extractPublicKey()).bytes,
  );
  final idB = await SessionManager.peerIdFor(
    (await keyB.extractPublicKey()).bytes,
  );

  SessionManager build(String me, SimpleKeyPair key) => SessionManager(
        peerId: me,
        staticKeyPair: key,
        clock: clock,
        onStep: (dest, step, body) =>
            wire.steps.add(_Step(me, dest, step, body)),
        onEstablished: (peer, role) =>
            (wire.established[me] ??= []).add('$peer:$role'),
        onFailed: (peer, why) => (wire.failures[me] ??= []).add(why),
      );

  wire.nodes = {idA: build(idA, keyA), idB: build(idB, keyB)};
  return wire;
}

void main() {
  group('a plain handshake', () {
    test('three steps and both sides have a session', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();

      expect(wire.nodes[a]!.hasSession(b), isTrue);
      expect(wire.nodes[b]!.hasSession(a), isTrue);
      expect(wire.failures, isEmpty);
    });

    test('the session actually carries a message', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();

      final sealed = await wire.nodes[a]!.seal(b, 'secret'.codeUnits);
      expect(sealed, isNotNull);
      final opened = await wire.nodes[b]!.open(
        a,
        sealed!.counter,
        sealed.ciphertext,
      );
      expect(opened, 'secret'.codeUnits);
    });

    test('exactly one side is the initiator', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      await wire.nodes[ids[0]]!.ensure(ids[1]);
      await wire.deliverAll();

      final roles = wire.established.values
          .expand((e) => e)
          .map((e) => e.split(':').last)
          .toList();
      expect(roles..sort(), ['initiator', 'responder']);
    });

    test('asking twice does not start a second handshake', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      await wire.nodes[ids[0]]!.ensure(ids[1]);
      final afterFirst = wire.steps.length;
      await wire.nodes[ids[0]]!.ensure(ids[1]);
      expect(wire.steps.length, afterFirst);
    });

    test('a node never handshakes with itself', () async {
      final wire = await twoNodes();
      final me = wire.nodes.keys.first;
      await wire.nodes[me]!.ensure(me);
      expect(wire.steps, isEmpty);
    });
  });

  group('both sides open at once', () {
    test('the collision still ends in one working session', () async {
      // The case that made a tie break necessary. Both call ensure before
      // either has heard anything, so two step 0s cross on the wire.
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.nodes[b]!.ensure(a);
      await wire.deliverAll();

      expect(wire.nodes[a]!.hasSession(b), isTrue);
      expect(wire.nodes[b]!.hasSession(a), isTrue);
      expect(wire.failures, isEmpty);
    });

    test('the lower id ends up the initiator', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList()..sort();
      final (lower, higher) = (ids[0], ids[1]);

      await wire.nodes[lower]!.ensure(higher);
      await wire.nodes[higher]!.ensure(lower);
      await wire.deliverAll();

      expect(wire.established[lower]!.single, endsWith(':initiator'));
      expect(wire.established[higher]!.single, endsWith(':responder'));
    });

    test('both sides agree on the same transcript', () async {
      // If a collision left them on different transcripts they would each
      // think they had a session and be unable to talk.
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.nodes[b]!.ensure(a);
      await wire.deliverAll();

      expect(
        wire.nodes[a]!.sessionWith(b)!.handshakeHash,
        wire.nodes[b]!.sessionWith(a)!.handshakeHash,
      );
    });
  });

  group('restarts', () {
    test('a peer that restarts can handshake again', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();

      // B loses its state, the way a process restart does, and opens again.
      wire.nodes[b]!.forget(a);
      await wire.nodes[b]!.ensure(a);
      await wire.deliverAll();

      expect(wire.nodes[a]!.hasSession(b), isTrue);
      expect(wire.nodes[b]!.hasSession(a), isTrue);
      expect(
        wire.nodes[a]!.sessionWith(b)!.handshakeHash,
        wire.nodes[b]!.sessionWith(a)!.handshakeHash,
      );
    });

    test('an unproven step 0 does not knock out a working session', () async {
      // Otherwise anyone could drop a step 0 on the mesh and cut a session
      // without ever proving who they are.
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();
      final before = wire.nodes[a]!.sessionWith(b)!.handshakeHash;

      await wire.nodes[a]!.handleStep(b, 0, Uint8List(32));
      expect(wire.nodes[a]!.hasSession(b), isTrue);
      expect(wire.nodes[a]!.sessionWith(b)!.handshakeHash, before);
    });
  });

  group('rejection', () {
    test('a step that does not authenticate fails the handshake', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      // Deliver step 0, then corrupt the reply.
      final first = wire.steps.removeAt(0);
      await wire.nodes[b]!.handleStep(first.from, first.step, first.body);
      final reply = wire.steps.removeAt(0);
      final broken = Uint8List.fromList(reply.body)..[40] ^= 0xff;

      await wire.nodes[a]!.handleStep(reply.from, reply.step, broken);

      expect(wire.failures[a], contains(SessionFailure.badMessage));
      expect(wire.nodes[a]!.hasSession(b), isFalse);
    });

    test('a key that does not match the id it claims is refused', () async {
      // The impersonation check. Someone answers for a peer id that is not
      // theirs, and the handshake itself succeeds because it authenticates
      // whoever actually replied.
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);
      const impostor = 'ffffffffffffffff';

      await wire.nodes[a]!.ensure(impostor);
      final opening = wire.steps.removeAt(0);
      // B answers a message addressed to somebody else.
      await wire.nodes[b]!.handleStep(opening.from, opening.step, opening.body);
      final reply = wire.steps.removeAt(0);
      await wire.nodes[a]!.handleStep(impostor, reply.step, reply.body);

      expect(wire.failures[a], contains(SessionFailure.wrongIdentity));
      expect(wire.nodes[a]!.hasSession(impostor), isFalse);
    });

    test('steps for the wrong role are ignored', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      // An initiator never receives step 2.
      await wire.nodes[a]!.handleStep(b, 2, Uint8List(48));
      expect(wire.failures[a], isNull);
      expect(wire.nodes[a]!.isHandshaking(b), isTrue);
    });

    test('a step with nothing in flight is ignored', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      await wire.nodes[ids[0]]!.handleStep(ids[1], 1, Uint8List(48));
      expect(wire.failures, isEmpty);
      expect(wire.steps, isEmpty);
    });

    test('sealing without a session yields nothing', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      expect(await wire.nodes[ids[0]]!.seal(ids[1], 'x'.codeUnits), isNull);
    });

    test('opening without a session throws', () async {
      final wire = await twoNodes();
      final ids = wire.nodes.keys.toList();
      expect(
        () => wire.nodes[ids[0]]!.open(ids[1], 0, Uint8List(32)),
        throwsA(isA<NoiseError>()),
      );
    });
  });

  group('timeouts', () {
    test('a handshake that stalls is given up and can be retried', () async {
      // A step can simply be lost: it floods like anything else and nothing
      // acknowledges it. Without expiry the pair could never try again.
      var now = DateTime(2026, 1, 1, 12);
      final wire = await twoNodes(clock: () => now);
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      wire.steps.clear(); // the opening step never arrives
      expect(wire.nodes[a]!.isHandshaking(b), isTrue);

      expect(wire.nodes[a]!.sweep().isEmpty, isTrue);

      now = now.add(const Duration(seconds: 30));
      expect(wire.nodes[a]!.sweep().stalledHandshakes, [b]);
      expect(wire.failures[a], contains(SessionFailure.timeout));
      expect(wire.nodes[a]!.isHandshaking(b), isFalse);

      // And a retry now works.
      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();
      expect(wire.nodes[a]!.hasSession(b), isTrue);
    });

    test('a session that keeps being seen is kept', () async {
      var now = DateTime(2026, 1, 1, 12);
      final wire = await twoNodes(clock: () => now);
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();

      // Five hours of a peer that keeps showing up.
      for (var i = 0; i < 60; i++) {
        now = now.add(const Duration(minutes: 5));
        wire.nodes[a]!.noteSeen(b);
        expect(wire.nodes[a]!.sweep().idleSessions, isEmpty);
      }
      expect(wire.nodes[a]!.hasSession(b), isTrue);
    });

    test('a session nobody has heard from is dropped', () async {
      // The bug this fixes: sessions were never removed, so every peer ever
      // met stayed forever and kept being offered as a private recipient.
      var now = DateTime(2026, 1, 1, 12);
      final wire = await twoNodes(clock: () => now);
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();
      expect(wire.nodes[a]!.hasSession(b), isTrue);

      now = now.add(const Duration(minutes: 5));
      expect(wire.nodes[a]!.sweep().idleSessions, isEmpty);

      now = now.add(const Duration(minutes: 10));
      expect(wire.nodes[a]!.sweep().idleSessions, [b]);
      expect(wire.nodes[a]!.hasSession(b), isFalse);
    });

    test('a relayed peer stays fresh without ever sending a hello', () async {
      // A hello is per link and never relayed, so a peer two hops away never
      // sends one. Freshness has to come from any traffic, or exactly the
      // sessions that only work through a relay would be the ones expired.
      var now = DateTime(2026, 1, 1, 12);
      final wire = await twoNodes(clock: () => now);
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();

      now = now.add(const Duration(minutes: 9));
      // A sealed message arriving is evidence enough.
      final sealed = await wire.nodes[b]!.seal(a, 'still here'.codeUnits);
      await wire.nodes[a]!.open(b, sealed!.counter, sealed.ciphertext);
      wire.nodes[a]!.noteSeen(b);

      now = now.add(const Duration(minutes: 9));
      expect(wire.nodes[a]!.sweep().idleSessions, isEmpty);
      expect(wire.nodes[a]!.hasSession(b), isTrue);
    });

    test('a handshake step counts as having seen the peer', () async {
      var now = DateTime(2026, 1, 1, 12);
      final wire = await twoNodes(clock: () => now);
      final ids = wire.nodes.keys.toList();
      final (a, b) = (ids[0], ids[1]);

      await wire.nodes[a]!.ensure(b);
      await wire.deliverAll();

      now = now.add(const Duration(minutes: 9));
      // Anything from them, even a step that goes nowhere.
      await wire.nodes[a]!.handleStep(b, 1, Uint8List(48));

      now = now.add(const Duration(minutes: 9));
      expect(wire.nodes[a]!.sweep().idleSessions, isEmpty);
    });
  });

  group('the session cap', () {
    test('holds at the limit, dropping the least recently seen', () async {
      // Same reasoning as the fragment assembler: a bound never reached in
      // normal use is still what separates a busy day from an app that grows
      // until it is killed.
      var now = DateTime(2026, 1, 1, 12);

      final hubKey = await X25519().newKeyPair();
      final hubId = await SessionManager.peerIdFor(
        (await hubKey.extractPublicKey()).bytes,
      );

      // [from, to, step, body], held rather than delivered, so the exchange is
      // deterministic instead of racing on the event loop.
      final queue = <(String, String, int, Uint8List)>[];
      final peers = <String, SessionManager>{};

      final hub = SessionManager(
        peerId: hubId,
        staticKeyPair: hubKey,
        maxSessions: 4,
        clock: () => now,
        onStep: (dest, step, body) => queue.add((hubId, dest, step, body)),
      );

      Future<void> drain() async {
        while (queue.isNotEmpty) {
          final (from, to, step, body) = queue.removeAt(0);
          final target = to == hubId ? hub : peers[to];
          await target?.handleStep(from, step, body);
        }
      }

      final order = <String>[];
      for (var i = 0; i < 6; i++) {
        final key = await X25519().newKeyPair();
        final id = await SessionManager.peerIdFor(
          (await key.extractPublicKey()).bytes,
        );
        order.add(id);
        peers[id] = SessionManager(
          peerId: id,
          staticKeyPair: key,
          clock: () => now,
          onStep: (dest, step, body) => queue.add((id, dest, step, body)),
        );

        await peers[id]!.ensure(hubId);
        await drain();
        now = now.add(const Duration(minutes: 1));
      }

      expect(hub.establishedPeers.length, 4);
      // The two oldest went, the newest stayed.
      expect(hub.hasSession(order[0]), isFalse);
      expect(hub.hasSession(order[1]), isFalse);
      expect(hub.hasSession(order[5]), isTrue);
    });
  });
}
