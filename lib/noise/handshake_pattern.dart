/// The tokens a Noise message pattern is built from.
///
/// Straight out of the spec. `e` and `s` put a key on the wire, the two letter
/// ones are Diffie-Hellman operations naming whose key is used: the initiator's
/// first, the responder's second. So `es` is always the initiator's ephemeral
/// against the responder's static, whichever side is currently writing.
enum Token { e, s, ee, es, se, ss }

/// One handshake pattern: what is known before the handshake starts, and the
/// sequence of messages that follow.
///
/// This is data rather than code on purpose. Every pattern runs through the
/// same interpreter, which is what makes it possible to check the
/// implementation against the official vectors for patterns the app itself
/// never uses.
class HandshakePattern {
  const HandshakePattern({
    required this.name,
    required this.initiatorPreMessage,
    required this.responderPreMessage,
    required this.messages,
  });

  /// The pattern name as it appears in a protocol name, such as `XX`.
  final String name;

  /// Keys the initiator sends ahead of time, so both sides already have them.
  /// Only ever `e`, `s`, or both.
  final List<Token> initiatorPreMessage;

  /// Keys the responder sends ahead of time.
  final List<Token> responderPreMessage;

  /// The messages themselves, alternating initiator, responder, initiator.
  final List<List<Token>> messages;

  /// The pattern this app uses.
  ///
  /// XX because it is the mutual-authentication pattern that assumes nothing:
  /// neither side needs to know the other's static key in advance, which is the
  /// only workable assumption in a mesh where you meet strangers. Both sides
  /// end up knowing who the other is, and the transport keys are forward
  /// secret.
  ///
  ///   -> e
  ///   <- e, ee, s, es
  ///   -> s, se
  static const xx = HandshakePattern(
    name: 'XX',
    initiatorPreMessage: [],
    responderPreMessage: [],
    messages: [
      [Token.e],
      [Token.e, Token.ee, Token.s, Token.es],
      [Token.s, Token.se],
    ],
  );
}
