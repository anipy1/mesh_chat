import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/noise/handshake_pattern.dart';
import 'package:mesh_chat/noise/noise_protocol.dart';

/// The official Noise vectors, replayed message for message.
///
/// This is the only thing that makes a hand written Noise implementation
/// defensible. A round trip test proves an implementation can talk to itself,
/// which a confidently wrong implementation also does. These vectors were
/// produced by a different implementation entirely, so matching them byte for
/// byte is evidence about the spec rather than about our own assumptions.
///
/// Fifteen fundamental patterns rather than just XX. The token interpreter is
/// shared, so a pattern the app never runs still exercises the same code, and
/// tokens like ss and the pre-message handling only appear in the others.
void main() {
  /// The patterns, transcribed from the Noise spec revision 34.
  ///
  /// A mistake here cannot produce a false pass. The vector was generated from
  /// the real pattern, so a wrong transcription simply fails to match.
  const patterns = <String, HandshakePattern>{
    'N': HandshakePattern(
      name: 'N',
      initiatorPreMessage: [],
      responderPreMessage: [Token.s],
      messages: [
        [Token.e, Token.es],
      ],
    ),
    'K': HandshakePattern(
      name: 'K',
      initiatorPreMessage: [Token.s],
      responderPreMessage: [Token.s],
      messages: [
        [Token.e, Token.es, Token.ss],
      ],
    ),
    'X': HandshakePattern(
      name: 'X',
      initiatorPreMessage: [],
      responderPreMessage: [Token.s],
      messages: [
        [Token.e, Token.es, Token.s, Token.ss],
      ],
    ),
    'NN': HandshakePattern(
      name: 'NN',
      initiatorPreMessage: [],
      responderPreMessage: [],
      messages: [
        [Token.e],
        [Token.e, Token.ee],
      ],
    ),
    'NK': HandshakePattern(
      name: 'NK',
      initiatorPreMessage: [],
      responderPreMessage: [Token.s],
      messages: [
        [Token.e, Token.es],
        [Token.e, Token.ee],
      ],
    ),
    'NX': HandshakePattern(
      name: 'NX',
      initiatorPreMessage: [],
      responderPreMessage: [],
      messages: [
        [Token.e],
        [Token.e, Token.ee, Token.s, Token.es],
      ],
    ),
    'XN': HandshakePattern(
      name: 'XN',
      initiatorPreMessage: [],
      responderPreMessage: [],
      messages: [
        [Token.e],
        [Token.e, Token.ee],
        [Token.s, Token.se],
      ],
    ),
    'XK': HandshakePattern(
      name: 'XK',
      initiatorPreMessage: [],
      responderPreMessage: [Token.s],
      messages: [
        [Token.e, Token.es],
        [Token.e, Token.ee],
        [Token.s, Token.se],
      ],
    ),
    'XX': HandshakePattern.xx,
    'KN': HandshakePattern(
      name: 'KN',
      initiatorPreMessage: [Token.s],
      responderPreMessage: [],
      messages: [
        [Token.e],
        [Token.e, Token.ee, Token.se],
      ],
    ),
    'KK': HandshakePattern(
      name: 'KK',
      initiatorPreMessage: [Token.s],
      responderPreMessage: [Token.s],
      messages: [
        [Token.e, Token.es, Token.ss],
        [Token.e, Token.ee, Token.se],
      ],
    ),
    'KX': HandshakePattern(
      name: 'KX',
      initiatorPreMessage: [Token.s],
      responderPreMessage: [],
      messages: [
        [Token.e],
        [Token.e, Token.ee, Token.se, Token.s, Token.es],
      ],
    ),
    'IN': HandshakePattern(
      name: 'IN',
      initiatorPreMessage: [],
      responderPreMessage: [],
      messages: [
        [Token.e, Token.s],
        [Token.e, Token.ee, Token.se],
      ],
    ),
    'IK': HandshakePattern(
      name: 'IK',
      initiatorPreMessage: [],
      responderPreMessage: [Token.s],
      messages: [
        [Token.e, Token.es, Token.s, Token.ss],
        [Token.e, Token.ee, Token.se],
      ],
    ),
    'IX': HandshakePattern(
      name: 'IX',
      initiatorPreMessage: [],
      responderPreMessage: [],
      messages: [
        [Token.e, Token.s],
        [Token.e, Token.ee, Token.se, Token.s, Token.es],
      ],
    ),
  };

  final raw = File(
    'test/vectors/noise_cacophony_25519_chachapoly_sha256.json',
  ).readAsStringSync();
  final vectors =
      (jsonDecode(raw) as Map<String, dynamic>)['vectors'] as List<dynamic>;

  test('the fixture covers every pattern we claim to test', () {
    expect(vectors.length, patterns.length);
  });

  for (final entry in vectors) {
    final v = entry as Map<String, dynamic>;
    final protocol = v['protocol_name'] as String;
    final patternName = protocol.split('_')[1];
    final pattern = patterns[patternName]!;

    test(protocol, () async {
      final initiatorStatic = await _staticOf(v['init_static'] as String?);
      final responderStatic = await _staticOf(v['resp_static'] as String?);

      final initiator = await HandshakeState.start(
        pattern: pattern,
        initiator: true,
        staticKeyPair: initiatorStatic,
        remoteStaticKey: _hexOrNull(v['init_remote_static'] as String?) ??
            // Patterns where the responder's static is known in advance take it
            // from the pre-message, which the vector only gives as resp_static.
            (pattern.responderPreMessage.contains(Token.s)
                ? await _publicOf(v['resp_static'] as String?)
                : null),
        prologue: _hex(v['init_prologue'] as String? ?? ''),
        fixedEphemeral: _hex(v['init_ephemeral'] as String),
      );

      final responder = await HandshakeState.start(
        pattern: pattern,
        initiator: false,
        staticKeyPair: responderStatic,
        remoteStaticKey: _hexOrNull(v['resp_remote_static'] as String?) ??
            (pattern.initiatorPreMessage.contains(Token.s)
                ? await _publicOf(v['init_static'] as String?)
                : null),
        prologue: _hex(v['resp_prologue'] as String? ?? ''),
        fixedEphemeral: v['resp_ephemeral'] == null
            ? null
            : _hex(v['resp_ephemeral'] as String),
      );

      final messages = v['messages'] as List<dynamic>;
      var index = 0;

      // Handshake messages first, alternating initiator then responder.
      while (!initiator.isComplete) {
        final m = messages[index] as Map<String, dynamic>;
        final payload = _hex(m['payload'] as String);
        final expected = _hex(m['ciphertext'] as String);

        final (writer, reader) =
            index.isEven ? (initiator, responder) : (responder, initiator);

        final produced = await writer.writeMessage(payload);
        expect(
          _toHex(produced),
          _toHex(expected),
          reason: '$protocol handshake message $index',
        );

        final received = await reader.readMessage(produced);
        expect(_toHex(received), _toHex(payload),
            reason: '$protocol payload $index');
        index++;
      }

      // Both sides must have arrived at the same transcript. If these differ
      // the handshake "succeeded" while the two sides disagree about what
      // happened, which is exactly what an attacker wants.
      expect(_toHex(initiator.handshakeHash), _toHex(responder.handshakeHash));
      if (v['handshake_hash'] != null) {
        expect(
          _toHex(initiator.handshakeHash),
          v['handshake_hash'] as String,
          reason: '$protocol handshake hash',
        );
      }

      final (initSend, initRecv) = await initiator.split();
      final (respSend, respRecv) = await responder.split();

      // One-way patterns have no return channel, so every transport message
      // comes from the initiator. Interactive ones keep alternating.
      final oneWay = pattern.messages.length == 1;

      for (; index < messages.length; index++) {
        final m = messages[index] as Map<String, dynamic>;
        final payload = _hex(m['payload'] as String);
        final expected = _hex(m['ciphertext'] as String);

        final fromInitiator = oneWay || index.isEven;
        final send = fromInitiator ? initSend : respSend;
        final recv = fromInitiator ? respRecv : initRecv;

        final produced = await send.encryptWithAd(const <int>[], payload);
        expect(
          _toHex(produced),
          _toHex(expected),
          reason: '$protocol transport message $index',
        );

        final opened = await recv.decryptWithAd(const <int>[], produced);
        expect(_toHex(opened), _toHex(payload),
            reason: '$protocol transport payload $index');
      }
    });
  }
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List? _hexOrNull(String? s) => s == null ? null : _hex(s);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<SimpleKeyPair?> _staticOf(String? hex) async =>
    hex == null ? null : X25519().newKeyPairFromSeed(_hex(hex));

Future<Uint8List?> _publicOf(String? privateHex) async {
  if (privateHex == null) return null;
  final pair = await X25519().newKeyPairFromSeed(_hex(privateHex));
  return Uint8List.fromList((await pair.extractPublicKey()).bytes);
}
