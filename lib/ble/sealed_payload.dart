import 'dart:convert';
import 'dart:typed_data';

/// What a sealed message actually contains.
///
/// The bytes inside a session used to be raw UTF-8, which was fine while chat
/// text was the only thing anyone sent. Reusing the Noise session for the
/// internet transport changed that: a peer has to be told our Nostr address,
/// and it has to arrive somewhere an attacker cannot forge. Inside the session
/// is the only such place, because only the real peer can seal to it.
///
///   [kind:1][body]
///
/// One byte, because this sits inside a channel that is already authenticated
/// and length delimited. There is nothing to validate here beyond the kind, and
/// an unknown kind is skipped rather than shown, on the same reasoning as the
/// outer frame: a peer running a newer build should not turn into visible
/// nonsense on an older one.
enum SealedKind {
  /// A chat message the user typed. UTF-8.
  text(1),

  /// The sender's Nostr public key, 32 bytes, so we can reach them when the
  /// radio cannot. Only meaningful inside a session: an unauthenticated claim
  /// about somebody's npub would let an attacker redirect their traffic.
  nostrAddress(2);

  const SealedKind(this.code);

  final int code;

  static SealedKind? from(int code) {
    for (final kind in SealedKind.values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

class SealedPayload {
  const SealedPayload(this.kind, this.body);

  final SealedKind kind;
  final Uint8List body;

  /// The body as text, for [SealedKind.text].
  String get text => utf8.decode(body, allowMalformed: true);

  /// The body as a lowercase hex string, for [SealedKind.nostrAddress].
  String get hex {
    final out = StringBuffer();
    for (final b in body) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  static Uint8List encodeText(String text) {
    final body = utf8.encode(text);
    return Uint8List(1 + body.length)
      ..[0] = SealedKind.text.code
      ..setRange(1, 1 + body.length, body);
  }

  /// [pubkeyHex] is a Nostr public key, 64 hex characters.
  static Uint8List encodeNostrAddress(String pubkeyHex) {
    if (pubkeyHex.length != 64) {
      throw ArgumentError('a nostr pubkey is 64 hex characters');
    }
    final out = Uint8List(1 + 32)..[0] = SealedKind.nostrAddress.code;
    for (var i = 0; i < 32; i++) {
      final byte =
          int.tryParse(pubkeyHex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) throw ArgumentError('not hex: "$pubkeyHex"');
      out[1 + i] = byte;
    }
    return out;
  }

  /// Returns null for anything that is not a payload we understand.
  static SealedPayload? parse(List<int> plaintext) {
    if (plaintext.isEmpty) return null;
    final kind = SealedKind.from(plaintext[0]);
    if (kind == null) return null;

    final body = Uint8List.fromList(plaintext.sublist(1));
    // A Nostr key that is not 32 bytes is not a Nostr key, and accepting one
    // would mean addressing internet traffic at nothing.
    if (kind == SealedKind.nostrAddress && body.length != 32) return null;
    return SealedPayload(kind, body);
  }
}
