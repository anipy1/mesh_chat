/// Messages waiting for a session, held as plaintext.
///
/// Plaintext on purpose, and it is the whole reason this works. A sealed
/// message is bound to the session that sealed it, so ciphertext held for an
/// absent peer only opens while that exact session still exists on both sides.
/// Sessions expire after ten minutes of silence and a restart destroys them
/// outright, which is exactly the situation waiting was for. Keeping the words
/// and sealing them against whatever session exists on arrival survives expiry,
/// restarts and rotation.
///
/// It also means this cannot be done by a relay. A relay holds bytes it cannot
/// read, so it can never re-seal them. Only the sender can wait usefully.
class OutboxItem {
  OutboxItem(this.text, this.queuedAt);

  final String text;
  final DateTime queuedAt;
}

/// What one delivery attempt produced.
class OutboxFlush {
  const OutboxFlush(this.peer, this.messages);

  final String peer;
  final List<String> messages;
}

class Outbox {
  Outbox({
    this.maxPerPeer = 20,
    this.maxPeers = 16,
    this.ttl = const Duration(hours: 1),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Messages held for any one peer. Beyond this the oldest goes, because a
  /// conversation nobody is receiving should not grow without limit.
  final int maxPerPeer;

  /// Peers we will hold anything for at all. The least recently written to is
  /// dropped first, on the reasoning that whoever you spoke to last is who you
  /// are most likely still trying to reach.
  final int maxPeers;

  /// How long a message waits before being given up on.
  ///
  /// An hour rather than a few minutes: unlike a session, plaintext does not
  /// go stale, and the whole point is to outlast an absence. Unlike forever,
  /// because a message the reader eventually gets hours late is often worse
  /// than one that never arrives.
  final Duration ttl;

  final DateTime Function() _now;
  final Map<String, List<OutboxItem>> _waiting = {};

  int get peerCount => _waiting.length;

  int get messageCount =>
      _waiting.values.fold(0, (sum, list) => sum + list.length);

  int pendingFor(String peer) => _waiting[peer]?.length ?? 0;

  Iterable<String> get peers => _waiting.keys;

  void add(String peer, String text) {
    final list = _waiting.putIfAbsent(peer, () => <OutboxItem>[]);
    list.add(OutboxItem(text, _now()));
    if (list.length > maxPerPeer) list.removeAt(0);
    _enforcePeerCap();
  }

  /// Hands over everything waiting for [peer] and forgets it.
  ///
  /// Handing over and forgetting in one step is deliberate. There is no
  /// acknowledgement anywhere in this mesh, so "sent" is the only signal
  /// available, and holding a copy back for a delivery report that will never
  /// come would just mean sending everything twice.
  List<String> take(String peer) {
    final list = _waiting.remove(peer);
    if (list == null) return const [];
    return list.map((item) => item.text).toList();
  }

  /// Drops messages that waited too long. Returns how many went, per peer.
  Map<String, int> expire() {
    final now = _now();
    final dropped = <String, int>{};
    for (final peer in _waiting.keys.toList()) {
      final list = _waiting[peer]!;
      final before = list.length;
      list.removeWhere((item) => now.difference(item.queuedAt) >= ttl);
      final gone = before - list.length;
      if (gone > 0) dropped[peer] = gone;
      if (list.isEmpty) _waiting.remove(peer);
    }
    return dropped;
  }

  void clear() => _waiting.clear();

  void _enforcePeerCap() {
    while (_waiting.length > maxPeers) {
      String? oldest;
      DateTime? oldestAt;
      for (final entry in _waiting.entries) {
        // A peer is as recent as its newest message.
        final newest = entry.value.last.queuedAt;
        if (oldestAt == null || newest.isBefore(oldestAt)) {
          oldest = entry.key;
          oldestAt = newest;
        }
      }
      if (oldest == null) return;
      _waiting.remove(oldest);
    }
  }
}
