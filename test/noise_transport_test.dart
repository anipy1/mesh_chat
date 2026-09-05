import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/noise/handshake_pattern.dart';
import 'package:mesh_chat/noise/noise_protocol.dart';
import 'package:mesh_chat/noise/noise_transport.dart';

void main() {
  group('replay window', () {
    test('accepts a fresh counter once and never again', () {
      final w = ReplayWindow();
      expect(w.accept(0), isTrue);
      expect(w.accept(0), isFalse);
    });

    test('accepts in order', () {
      final w = ReplayWindow();
      for (var i = 0; i < 200; i++) {
        expect(w.accept(i), isTrue, reason: 'counter $i');
      }
    });

    test('accepts out of order, which is the entire point', () {
      // Two messages sent A then B genuinely arrive B then A on this mesh.
      final w = ReplayWindow();
      expect(w.accept(5), isTrue);
      expect(w.accept(3), isTrue);
      expect(w.accept(4), isTrue);
      expect(w.accept(1), isTrue);
    });

    test('refuses a replay that arrived out of order', () {
      final w = ReplayWindow();
      expect(w.accept(5), isTrue);
      expect(w.accept(3), isTrue);
      expect(w.accept(3), isFalse);
      expect(w.accept(5), isFalse);
    });

    test('refuses anything older than the window', () {
      final w = ReplayWindow();
      expect(w.accept(0), isTrue);
      expect(w.accept(ReplayWindow.size + 10), isTrue);
      // 0 is now far behind the newest counter and cannot be judged.
      expect(w.accept(0), isFalse);
      expect(w.accept(1), isFalse);
    });

    test('a big jump forwards does not leave stale bits behind', () {
      final w = ReplayWindow();
      expect(w.accept(1), isTrue);
      expect(w.accept(2), isTrue);
      expect(w.accept(1000), isTrue);
      // Everything inside the new window is untouched and must be accepted.
      expect(w.accept(999), isTrue);
      expect(w.accept(998), isTrue);
      expect(w.accept(999), isFalse);
    });

    test('isNew does not consume the counter', () {
      final w = ReplayWindow();
      expect(w.isNew(7), isTrue);
      expect(w.isNew(7), isTrue);
      expect(w.accept(7), isTrue);
      expect(w.isNew(7), isFalse);
    });

    test('a negative counter is never new', () {
      expect(ReplayWindow().isNew(-1), isFalse);
    });
  });

  group('transport', () {
    Future<(NoiseTransport, NoiseTransport)> pair() async {
      final a = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: true,
        staticKeyPair: await X25519().newKeyPair(),
      );
      final b = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: false,
        staticKeyPair: await X25519().newKeyPair(),
      );
      await b.readMessage(await a.writeMessage());
      await a.readMessage(await b.writeMessage());
      await b.readMessage(await a.writeMessage());

      final (aSend, aRecv) = await a.split();
      final (bSend, bRecv) = await b.split();
      return (
        NoiseTransport(
          send: aSend,
          receive: aRecv,
          handshakeHash: a.handshakeHash,
          remoteStaticKey: a.remoteStaticKey!,
        ),
        NoiseTransport(
          send: bSend,
          receive: bRecv,
          handshakeHash: b.handshakeHash,
          remoteStaticKey: b.remoteStaticKey!,
        ),
      );
    }

    test('a sealed message opens at the other end', () async {
      final (a, b) = await pair();
      final sealed = await a.seal('hello'.codeUnits);
      expect(
          await b.open(sealed.counter, sealed.ciphertext), 'hello'.codeUnits);
    });

    test('messages open out of order', () async {
      // The reason this class exists. Plain Noise transport would fail here.
      final (a, b) = await pair();
      final one = await a.seal('one'.codeUnits);
      final two = await a.seal('two'.codeUnits);
      final three = await a.seal('three'.codeUnits);

      expect(await b.open(three.counter, three.ciphertext), 'three'.codeUnits);
      expect(await b.open(one.counter, one.ciphertext), 'one'.codeUnits);
      expect(await b.open(two.counter, two.ciphertext), 'two'.codeUnits);
    });

    test('a replayed message is refused', () async {
      final (a, b) = await pair();
      final sealed = await a.seal('once'.codeUnits);
      await b.open(sealed.counter, sealed.ciphertext);
      expect(
        () => b.open(sealed.counter, sealed.ciphertext),
        throwsA(isA<NoiseError>()),
      );
    });

    test('a forged message does not consume a counter', () async {
      // If a forgery burned its counter, anyone able to inject one packet could
      // stop the real message that follows from ever being accepted.
      final (a, b) = await pair();
      final real = await a.seal('genuine'.codeUnits);
      final forged = List<int>.from(real.ciphertext)..[0] ^= 0xff;

      expect(
        () => b.open(real.counter, forged),
        throwsA(isA<NoiseError>()),
      );
      expect(
        await b.open(real.counter, real.ciphertext),
        'genuine'.codeUnits,
      );
    });

    test('both directions have independent counters', () async {
      final (a, b) = await pair();
      final there = await a.seal('x'.codeUnits);
      final back = await b.seal('y'.codeUnits);
      expect(there.counter, 0);
      expect(back.counter, 0);
      expect(await b.open(there.counter, there.ciphertext), 'x'.codeUnits);
      expect(await a.open(back.counter, back.ciphertext), 'y'.codeUnits);
    });

    test('each side knows the other key from the handshake', () async {
      final (a, b) = await pair();
      expect(a.remoteStaticKey.length, 32);
      expect(b.remoteStaticKey.length, 32);
      expect(a.handshakeHash, b.handshakeHash);
    });

    test('associated data has to match', () async {
      final (a, b) = await pair();
      final sealed = await a.seal('hi'.codeUnits, ad: 'context'.codeUnits);
      expect(
        () => b.open(sealed.counter, sealed.ciphertext, ad: 'other'.codeUnits),
        throwsA(isA<NoiseError>()),
      );
      expect(
        await b.open(sealed.counter, sealed.ciphertext,
            ad: 'context'.codeUnits),
        'hi'.codeUnits,
      );
    });
  });
}
