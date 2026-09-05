import 'dart:typed_data';

import 'frame.dart';

enum AssemblyStatus {
  /// First piece of a message we had not seen before.
  started,

  /// Piece recorded, still waiting for others.
  stored,

  /// We already held this index. Nothing changed.
  duplicate,

  /// Every piece is in. [AssemblyOutcome.data] holds the rebuilt bytes.
  complete,

  /// The message would grow past the byte limit, so it was abandoned.
  oversized,
}

class AssemblyOutcome {
  const AssemblyOutcome(this.status,
      {this.data, this.have = 0, this.total = 0});

  final AssemblyStatus status;
  final Uint8List? data;
  final int have;
  final int total;
}

class _Assembly {
  _Assembly(this.total, DateTime now)
      : startedAt = now,
        lastPieceAt = now;

  final int total;
  final DateTime startedAt;
  DateTime lastPieceAt;
  final Map<int, Uint8List> pieces = {};
  int bytes = 0;

  bool get isComplete => pieces.length == total;

  Uint8List join() {
    final out = Uint8List(bytes);
    var at = 0;
    for (var i = 0; i < total; i++) {
      final piece = pieces[i];
      if (piece == null) continue;
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

/// Puts fragmented messages back together, and refuses to be used as a memory
/// sink while doing it.
///
/// Three limits, because they stop three different things:
///
/// - [maxAssemblies] caps how many messages can be part-built at once, so many
///   peers each starting one cannot add up. The oldest is dropped to make room.
/// - [maxBytes] caps one message, so a single peer cannot stream forever.
/// - [expiry] drops assemblies that go quiet, so a peer that sends piece one of
///   forty and walks away does not hold memory for the rest of the session.
///
/// Keyed on the fragment id alone. bitchat keys on (sender, id) so one peer
/// cannot disturb another's reassembly, which we cannot do because there is no
/// sender in our envelope, on purpose. With 8 random bytes and at most
/// [maxAssemblies] in flight an accidental collision is not a practical worry.
/// A deliberate one is possible, and worth fixing when frames are authenticated
/// and the key can become (origin, id).
class FragmentAssembler {
  FragmentAssembler({
    this.maxAssemblies = 8,
    this.maxBytes = 64 * 1024,
    this.expiry = const Duration(seconds: 30),
  });

  final int maxAssemblies;
  final int maxBytes;
  final Duration expiry;

  final Map<String, _Assembly> _open = {};

  int get inFlight => _open.length;

  void clear() => _open.clear();

  /// Ids dropped by the last [add] because they went quiet.
  final List<String> expiredIds = [];

  AssemblyOutcome add(FragmentPart part, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _expire(at);

    var assembly = _open[part.id];
    var status = AssemblyStatus.stored;

    if (assembly == null) {
      if (_open.length >= maxAssemblies) _dropOldest();
      assembly = _Assembly(part.total, at);
      _open[part.id] = assembly;
      status = AssemblyStatus.started;
    }

    if (assembly.pieces.containsKey(part.index)) {
      return AssemblyOutcome(
        AssemblyStatus.duplicate,
        have: assembly.pieces.length,
        total: assembly.total,
      );
    }

    if (assembly.bytes + part.chunk.length > maxBytes) {
      _open.remove(part.id);
      return AssemblyOutcome(
        AssemblyStatus.oversized,
        have: assembly.pieces.length,
        total: assembly.total,
      );
    }

    assembly.pieces[part.index] = part.chunk;
    assembly.bytes += part.chunk.length;
    assembly.lastPieceAt = at;

    if (!assembly.isComplete) {
      return AssemblyOutcome(
        status,
        have: assembly.pieces.length,
        total: assembly.total,
      );
    }

    _open.remove(part.id);
    return AssemblyOutcome(
      AssemblyStatus.complete,
      data: assembly.join(),
      have: assembly.total,
      total: assembly.total,
    );
  }

  void _expire(DateTime now) {
    expiredIds.clear();
    final cutoff = now.subtract(expiry);
    _open.removeWhere((id, a) {
      final stale = a.lastPieceAt.isBefore(cutoff);
      if (stale) expiredIds.add(id);
      return stale;
    });
  }

  void _dropOldest() {
    String? oldestId;
    DateTime? oldest;
    for (final e in _open.entries) {
      if (oldest == null || e.value.startedAt.isBefore(oldest)) {
        oldest = e.value.startedAt;
        oldestId = e.key;
      }
    }
    if (oldestId != null) _open.remove(oldestId);
  }
}
