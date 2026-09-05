import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'handshake_pattern.dart';
import 'noise_protocol.dart';
import 'noise_transport.dart';

/// Emits one handshake step towards [dest].
typedef HandshakeSender = void Function(String dest, int step, Uint8List body);

typedef SessionEvent = void Function(String peerId, String detail);

/// Why a handshake ended without a session.
enum SessionFailure {
  /// The peer's static key does not hash to the id we addressed. Either
  /// someone is impersonating a peer, or two nodes disagree about who is who.
  wrongIdentity,

  /// A step did not authenticate, or arrived malformed.
  badMessage,

  /// The handshake stopped part way and the clock ran out.
  timeout,
}

/// Runs Noise XX with peers and keeps the resulting sessions.
///
/// Sessions are keyed on peer id rather than on a link. Legs churn constantly
/// on this mesh, so a session tied to one dies with it, and a peer can stop
/// being a neighbour without stopping being reachable. Handshake steps are
/// ordinary relayable frames for the same reason.
///
/// Knows nothing about BLE or frames. It is handed steps and hands back steps,
/// which is what makes the awkward parts, collisions, restarts and timeouts,
/// testable on a desk instead of across three phones.
class SessionManager {
  SessionManager({
    required this.peerId,
    required SimpleKeyPair staticKeyPair,
    required HandshakeSender onStep,
    this.onEstablished,
    this.onFailed,
    this.handshakeTimeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  })  : _static = staticKeyPair,
        _onStep = onStep,
        _now = clock ?? DateTime.now;

  /// Our own id, the 16 hex characters of [NodeIdentity.peerId].
  final String peerId;

  final SimpleKeyPair _static;
  final HandshakeSender _onStep;
  final SessionEvent? onEstablished;
  final void Function(String peerId, SessionFailure why)? onFailed;

  /// How long a half finished handshake is kept before it is abandoned.
  ///
  /// A step can simply be lost: it floods like any other frame and nothing
  /// acknowledges it. Without this a single lost step would leave the pair
  /// unable to ever try again.
  final Duration handshakeTimeout;

  final DateTime Function() _now;

  final Map<String, NoiseTransport> _sessions = {};
  final Map<String, _Pending> _pending = {};

  Iterable<String> get establishedPeers => _sessions.keys;

  bool hasSession(String peer) => _sessions.containsKey(peer);

  bool isHandshaking(String peer) => _pending.containsKey(peer);

  NoiseTransport? sessionWith(String peer) => _sessions[peer];

  /// Starts a handshake with [peer] unless one is already up or under way.
  Future<void> ensure(String peer) async {
    if (peer == peerId) return;
    if (_sessions.containsKey(peer)) return;
    if (_pending.containsKey(peer)) return;
    await _beginAsInitiator(peer);
  }

  /// Drops a session and any handshake in progress.
  void forget(String peer) {
    _sessions.remove(peer);
    _pending.remove(peer);
  }

  /// Abandons handshakes that have gone quiet, so they can be retried.
  ///
  /// Returns the peers that were given up on.
  List<String> expire() {
    final now = _now();
    final dead = <String>[];
    _pending.removeWhere((peer, pending) {
      if (now.difference(pending.startedAt) < handshakeTimeout) return false;
      dead.add(peer);
      return true;
    });
    for (final peer in dead) {
      onFailed?.call(peer, SessionFailure.timeout);
    }
    return dead;
  }

  Future<void> _beginAsInitiator(String peer) async {
    final state = await HandshakeState.start(
      pattern: HandshakePattern.xx,
      initiator: true,
      staticKeyPair: _static,
    );
    _pending[peer] = _Pending(state, initiator: true, startedAt: _now());
    _onStep(peer, 0, await state.writeMessage());
  }

  /// Feeds one received handshake step in.
  Future<void> handleStep(String from, int step, Uint8List body) async {
    if (from == peerId) return;

    var pending = _pending[from];

    if (step == 0) {
      // A fresh opening move. Three ways to get here, and they need different
      // things.
      if (pending != null && pending.initiator) {
        // Both of us opened at once. The lower id initiates, the same tie
        // break used for dialling, so exactly one attempt survives.
        if (peerId.compareTo(from) < 0) {
          // We win. Their attempt will be abandoned when our step 0 reaches
          // them, so there is nothing to do here.
          return;
        }
        // We lose, so our own attempt goes and we answer theirs.
        _pending.remove(from);
        pending = null;
      } else if (pending != null) {
        // They restarted mid handshake. Start over from their new opening
        // rather than trying to continue a conversation they have forgotten.
        _pending.remove(from);
        pending = null;
      }

      // An established session is deliberately left alone until the new
      // handshake finishes. Otherwise anyone could drop a step 0 on the mesh
      // and knock out a working session without proving anything.
      final state = await HandshakeState.start(
        pattern: HandshakePattern.xx,
        initiator: false,
        staticKeyPair: _static,
      );
      final fresh = _Pending(state, initiator: false, startedAt: _now());
      _pending[from] = fresh;

      try {
        await state.readMessage(body);
        _onStep(from, 1, await state.writeMessage());
      } on NoiseError {
        _pending.remove(from);
        onFailed?.call(from, SessionFailure.badMessage);
      }
      return;
    }

    if (pending == null) return; // nothing in flight, so nothing to continue

    try {
      if (step == 1) {
        if (!pending.initiator) return; // responders do not receive step 1
        await pending.state.readMessage(body);
        _onStep(from, 2, await pending.state.writeMessage());
        await _finish(from, pending);
        return;
      }

      if (step == 2) {
        if (pending.initiator) return; // initiators do not receive step 2
        await pending.state.readMessage(body);
        await _finish(from, pending);
        return;
      }
    } on NoiseError {
      _pending.remove(from);
      onFailed?.call(from, SessionFailure.badMessage);
    }
  }

  Future<void> _finish(String peer, _Pending pending) async {
    _pending.remove(peer);

    final remote = pending.state.remoteStaticKey;
    if (remote == null) {
      onFailed?.call(peer, SessionFailure.badMessage);
      return;
    }

    // The id we addressed is a hash of the key we expect. Now that the
    // handshake has produced a key, check it is the right one. Without this the
    // channel is encrypted and authenticated to whoever answered, which is not
    // the same as to whoever we meant.
    final derived = await peerIdFor(remote);
    if (derived != peer) {
      onFailed?.call(peer, SessionFailure.wrongIdentity);
      return;
    }

    final (send, receive) = await pending.state.split();
    _sessions[peer] = NoiseTransport(
      send: send,
      receive: receive,
      handshakeHash: pending.state.handshakeHash,
      remoteStaticKey: remote,
    );
    onEstablished?.call(peer, pending.initiator ? 'initiator' : 'responder');
  }

  /// Seals [plaintext] for [peer]. Null when there is no session yet.
  Future<SealedMessage?> seal(String peer, List<int> plaintext) {
    final session = _sessions[peer];
    if (session == null) return Future.value(null);
    return session.seal(plaintext);
  }

  /// Opens a sealed message from [peer]. Throws [NoiseError] if it does not
  /// authenticate, is a replay, or there is no session.
  Future<Uint8List> open(String peer, int counter, List<int> ciphertext) {
    final session = _sessions[peer];
    if (session == null) throw NoiseError('no session with $peer');
    return session.open(counter, ciphertext);
  }

  /// The peer id a static key belongs to: the first 8 bytes of its SHA-256.
  static Future<String> peerIdFor(List<int> staticPublicKey) async {
    final digest = await Sha256().hash(staticPublicKey);
    final out = StringBuffer();
    for (final b in digest.bytes.take(8)) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}

class _Pending {
  _Pending(this.state, {required this.initiator, required this.startedAt});

  final HandshakeState state;
  final bool initiator;
  final DateTime startedAt;
}
