import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/noise/handshake_pattern.dart';
import 'package:mesh_chat/noise/noise_protocol.dart';

/// What the official vectors cannot tell us.
///
/// The vectors prove we produce the same bytes as everyone else for correct
/// input. They say nothing about what happens to wrong input, and an
/// implementation that accepts a forged message matches every vector perfectly.
void main() {
  Future<SimpleKeyPair> staticKey() => X25519().newKeyPair();

  /// Runs XX to completion and hands back both sides.
  Future<(HandshakeState, HandshakeState)> handshake({
    List<int> initiatorPrologue = const <int>[],
    List<int> responderPrologue = const <int>[],
    SimpleKeyPair? initiatorStatic,
    SimpleKeyPair? responderStatic,
  }) async {
    final a = await HandshakeState.start(
      pattern: HandshakePattern.xx,
      initiator: true,
      staticKeyPair: initiatorStatic ?? await staticKey(),
      prologue: initiatorPrologue,
    );
    final b = await HandshakeState.start(
      pattern: HandshakePattern.xx,
      initiator: false,
      staticKeyPair: responderStatic ?? await staticKey(),
      prologue: responderPrologue,
    );

    await b.readMessage(await a.writeMessage());
    await a.readMessage(await b.writeMessage());
    await b.readMessage(await a.writeMessage());
    return (a, b);
  }

  group('a completed XX handshake', () {
    test('leaves both sides agreeing on the transcript', () async {
      final (a, b) = await handshake();
      expect(a.isComplete, isTrue);
      expect(b.isComplete, isTrue);
      expect(a.handshakeHash, b.handshakeHash);
    });

    test('tells each side who the other actually is', () async {
      // The whole point of XX over NN. Without this the channel is encrypted
      // to nobody in particular.
      final aStatic = await staticKey();
      final bStatic = await staticKey();
      final (a, b) = await handshake(
        initiatorStatic: aStatic,
        responderStatic: bStatic,
      );

      expect(a.remoteStaticKey, (await bStatic.extractPublicKey()).bytes);
      expect(b.remoteStaticKey, (await aStatic.extractPublicKey()).bytes);
    });

    test('carries traffic in both directions', () async {
      final (a, b) = await handshake();
      final (aSend, aRecv) = await a.split();
      final (bSend, bRecv) = await b.split();

      final there = await aSend.encryptWithAd(const [], 'hello'.codeUnits);
      expect(await bRecv.decryptWithAd(const [], there), 'hello'.codeUnits);

      final back = await bSend.encryptWithAd(const [], 'hi'.codeUnits);
      expect(await aRecv.decryptWithAd(const [], back), 'hi'.codeUnits);
    });

    test('produces different keys every time it runs', () async {
      // If the ephemeral were ever reused, two sessions would share transport
      // keys and forward secrecy would be gone.
      final (a1, _) = await handshake();
      final (a2, _) = await handshake();
      expect(a1.handshakeHash, isNot(a2.handshakeHash));
    });
  });

  group('rejection', () {
    test('a tampered handshake message does not decrypt', () async {
      final a = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: true,
        staticKeyPair: await staticKey(),
      );
      final b = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: false,
        staticKeyPair: await staticKey(),
      );

      await b.readMessage(await a.writeMessage());
      final second = await b.writeMessage();
      // Flip one bit inside the encrypted static key.
      final tampered = Uint8List.fromList(second);
      tampered[40] ^= 0x01;

      expect(() => a.readMessage(tampered), throwsA(isA<NoiseError>()));
    });

    test('a tampered transport message does not decrypt', () async {
      final (a, b) = await handshake();
      final (aSend, _) = await a.split();
      final (_, bRecv) = await b.split();

      final sealed = await aSend.encryptWithAd(const [], 'hello'.codeUnits);
      final tampered = Uint8List.fromList(sealed);
      tampered[0] ^= 0x01;

      expect(
        () => bRecv.decryptWithAd(const [], tampered),
        throwsA(isA<NoiseError>()),
      );
    });

    test('a forgery does not desynchronise the session', () async {
      // A rejected message must not advance the nonce, or anyone able to inject
      // one packet could permanently break the channel for both parties.
      final (a, b) = await handshake();
      final (aSend, _) = await a.split();
      final (_, bRecv) = await b.split();

      final real = await aSend.encryptWithAd(const [], 'first'.codeUnits);
      final forged = Uint8List.fromList(real)..[0] ^= 0xff;

      expect(
        () => bRecv.decryptWithAd(const [], forged),
        throwsA(isA<NoiseError>()),
      );
      // The genuine message still opens afterwards.
      expect(await bRecv.decryptWithAd(const [], real), 'first'.codeUnits);
    });

    test('prologues that disagree fail the handshake', () async {
      // The prologue is how anything negotiated in the clear beforehand gets
      // bound into the transcript. If a mismatch were tolerated, tampering with
      // that negotiation would go unnoticed.
      final a = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: true,
        staticKeyPair: await staticKey(),
        prologue: 'version 1'.codeUnits,
      );
      final b = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: false,
        staticKeyPair: await staticKey(),
        prologue: 'version 2'.codeUnits,
      );

      await b.readMessage(await a.writeMessage());
      // The responder's reply is authenticated under a hash the initiator
      // cannot reproduce.
      final reply = await b.writeMessage();
      expect(() => a.readMessage(reply), throwsA(isA<NoiseError>()));
    });

    test('a truncated message is refused rather than half read', () async {
      final a = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: true,
        staticKeyPair: await staticKey(),
      );
      final b = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: false,
        staticKeyPair: await staticKey(),
      );
      final first = await a.writeMessage();

      expect(
        () => b.readMessage(first.sublist(0, 10)),
        throwsA(isA<NoiseError>()),
      );
    });
  });

  group('sequencing', () {
    test('writing out of turn is refused', () async {
      final a = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: true,
        staticKeyPair: await staticKey(),
      );
      await a.writeMessage();
      expect(() => a.writeMessage(), throwsA(isA<NoiseError>()));
    });

    test('reading out of turn is refused', () async {
      final b = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: false,
        staticKeyPair: await staticKey(),
      );
      // The responder has not received anything yet, so it cannot write.
      expect(() => b.writeMessage(), throwsA(isA<NoiseError>()));
    });

    test('splitting early is refused', () async {
      final a = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: true,
        staticKeyPair: await staticKey(),
      );
      expect(() => a.split(), throwsA(isA<NoiseError>()));
    });

    test('the initiator sends on the cipher the responder receives on',
        () async {
      // Getting the two halves of split the wrong way round produces two sides
      // that each work alone and cannot talk to each other.
      final (a, b) = await handshake();
      final (aSend, aRecv) = await a.split();
      final (bSend, bRecv) = await b.split();

      final one = await aSend.encryptWithAd(const [], 'x'.codeUnits);
      expect(await bRecv.decryptWithAd(const [], one), 'x'.codeUnits);

      final two = await bSend.encryptWithAd(const [], 'y'.codeUnits);
      expect(await aRecv.decryptWithAd(const [], two), 'y'.codeUnits);
    });
  });
}
