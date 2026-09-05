import 'dart:typed_data';

import 'noise_protocol.dart';

/// Remembers which counters have already been seen, so a replayed message is
/// refused without requiring messages to arrive in order.
///
/// Noise's transport counter is implicit: the sender counts up and the receiver
/// expects the next value. That assumes an ordered channel, and this mesh is
/// not one. Messages flood by several paths at once, each relay adds its own
/// random assessment delay, and two messages sent A then B genuinely do arrive
/// B then A. With an implicit counter the second one fails to decrypt and the
/// session is broken from then on.
///
/// So the counter travels with the message and this keeps track of what has
/// been used, the way WireGuard and DTLS do. A window rather than a set,
/// because a set of every counter ever seen grows forever.
class ReplayWindow {
  /// How far behind the newest counter a message may still be accepted.
  ///
  /// 64 because the bitmap is one int. In practice reordering here is on the
  /// order of a few messages: a piece waits at most a few hundred milliseconds
  /// per hop.
  static const size = 64;

  /// The highest counter accepted so far. -1 means nothing yet.
  int _highest = -1;

  /// One bit per counter below [_highest]. Bit 0 is _highest - 1.
  int _seen = 0;

  int get highest => _highest;

  /// Whether [counter] is new. Does not record it: call [accept] for that.
  bool isNew(int counter) {
    if (counter < 0) return false;
    if (counter > _highest) return true;
    if (counter == _highest) return false;
    final behind = _highest - counter;
    if (behind > size) return false;
    return (_seen >> (behind - 1)) & 1 == 0;
  }

  /// Records [counter] as seen. Returns false if it was already used or is too
  /// old to judge, in which case nothing is recorded.
  bool accept(int counter) {
    if (!isNew(counter)) return false;
    if (counter > _highest) {
      final jump = _highest < 0 ? counter + 1 : counter - _highest;
      if (jump >= size) {
        // The window moved past everything it was holding.
        _seen = 0;
      } else {
        // Shift the old entries down and mark the previous highest as seen.
        _seen = (_seen << jump) | (1 << (jump - 1));
      }
      _highest = counter;
      return true;
    }
    _seen |= 1 << (_highest - counter - 1);
    return true;
  }
}

/// One sealed message: the ciphertext, and the counter needed to open it.
class SealedMessage {
  const SealedMessage(this.counter, this.ciphertext);

  final int counter;
  final Uint8List ciphertext;
}

/// A live session with one peer, after the handshake.
///
/// Owns the send counter, so nothing outside can pick a nonce and destroy the
/// cipher by reusing one, and owns the replay window, so nothing outside can
/// forget to check.
class NoiseTransport {
  NoiseTransport({
    required CipherState send,
    required CipherState receive,
    required this.handshakeHash,
    required this.remoteStaticKey,
  })  : _send = send,
        _receive = receive;

  final CipherState _send;
  final CipherState _receive;

  /// The transcript both sides agreed on. Useful for binding anything else to
  /// this specific session.
  final Uint8List handshakeHash;

  /// Who we are actually talking to, as established by the handshake rather
  /// than as claimed by anyone.
  final Uint8List remoteStaticKey;

  final ReplayWindow _window = ReplayWindow();
  int _counter = 0;

  int get received => _window.highest;

  Future<SealedMessage> seal(
    List<int> plaintext, {
    List<int> ad = const <int>[],
  }) async {
    final counter = _counter;
    final ciphertext = await _send.encryptWithAdAt(counter, ad, plaintext);
    _counter++;
    return SealedMessage(counter, ciphertext);
  }

  /// Opens a sealed message.
  ///
  /// The counter is checked for replay only after the ciphertext authenticates,
  /// so a forged message cannot consume a counter and lock out the real one
  /// that follows it.
  Future<Uint8List> open(
    int counter,
    List<int> ciphertext, {
    List<int> ad = const <int>[],
  }) async {
    if (!_window.isNew(counter)) {
      throw NoiseError('counter $counter is a replay or too old');
    }
    final plaintext = await _receive.decryptWithAdAt(counter, ad, ciphertext);
    _window.accept(counter);
    return plaintext;
  }
}
