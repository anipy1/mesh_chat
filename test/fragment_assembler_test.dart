import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/ble/fragment_assembler.dart';
import 'package:mesh_chat/ble/frame.dart';

/// Pieces of a real message, so the tests exercise the same path the radio does.
List<FragmentPart> piecesOf(String text, {int chunkSize = 200}) {
  final frames = Frame.split(
    Frame.text(text).encode(),
    chunkSize: chunkSize,
    ttl: 3,
  )!;
  return frames.map((f) => FragmentPart.parse(f)!).toList();
}

void main() {
  test('rebuilds a message from its pieces', () {
    final a = FragmentAssembler();
    final parts = piecesOf('x' * 900);
    expect(parts.length, greaterThan(1));

    AssemblyOutcome? last;
    for (final p in parts) {
      last = a.add(p);
    }
    expect(last!.status, AssemblyStatus.complete);
    expect(Frame.decode(last.data!)!.text, 'x' * 900);
    expect(a.inFlight, 0, reason: 'finished assemblies are released');
  });

  test('order does not matter', () {
    final a = FragmentAssembler();
    final parts = piecesOf('y' * 900)..shuffle();
    AssemblyOutcome? last;
    for (final p in parts) {
      last = a.add(p);
    }
    expect(last!.status, AssemblyStatus.complete);
    expect(Frame.decode(last.data!)!.text, 'y' * 900);
  });

  test('a repeated piece changes nothing', () {
    final a = FragmentAssembler();
    final parts = piecesOf('z' * 900);
    a.add(parts[0]);
    final again = a.add(parts[0]);
    expect(again.status, AssemblyStatus.duplicate);
    expect(again.have, 1);
  });

  test('two messages interleave without mixing', () {
    final a = FragmentAssembler();
    final one = piecesOf('one' * 300);
    final two = piecesOf('two' * 300);

    AssemblyOutcome? finishedOne;
    AssemblyOutcome? finishedTwo;
    for (var i = 0; i < one.length || i < two.length; i++) {
      if (i < one.length) finishedOne = a.add(one[i]);
      if (i < two.length) finishedTwo = a.add(two[i]);
    }
    expect(Frame.decode(finishedOne!.data!)!.text, 'one' * 300);
    expect(Frame.decode(finishedTwo!.data!)!.text, 'two' * 300);
  });

  group('limits', () {
    test('drops the oldest when too many are part-built', () {
      final a = FragmentAssembler(maxAssemblies: 2);
      final first = piecesOf('a' * 900);
      final second = piecesOf('b' * 900);
      final third = piecesOf('c' * 900);

      var t = DateTime(2026);
      a.add(first[0], now: t);
      a.add(second[0], now: t = t.add(const Duration(seconds: 1)));
      expect(a.inFlight, 2);

      // The third start evicts the first, which is the oldest.
      a.add(third[0], now: t.add(const Duration(seconds: 1)));
      expect(a.inFlight, 2);

      // Finishing the first now cannot complete, its earlier piece is gone.
      for (final p in first.skip(1)) {
        final r = a.add(p);
        expect(r.status, isNot(AssemblyStatus.complete));
      }
    });

    test('abandons a message that would grow past the byte limit', () {
      final a = FragmentAssembler(maxBytes: 300);
      final parts = piecesOf('d' * 2000, chunkSize: 200);

      AssemblyStatus? last;
      for (final p in parts) {
        last = a.add(p).status;
        if (last == AssemblyStatus.oversized) break;
      }
      expect(last, AssemblyStatus.oversized);
      expect(a.inFlight, 0, reason: 'the whole thing is dropped, not trimmed');
    });

    test('gives up on an assembly that goes quiet', () {
      final a = FragmentAssembler(expiry: const Duration(seconds: 10));
      final parts = piecesOf('e' * 900);
      final t = DateTime(2026);

      a.add(parts[0], now: t);
      expect(a.inFlight, 1);

      // A later piece for something else sweeps the stale one out.
      final other = piecesOf('f' * 900);
      a.add(other[0], now: t.add(const Duration(seconds: 11)));
      expect(a.expiredIds.length, 1);
      expect(a.inFlight, 1, reason: 'only the fresh one is left');
    });

    test('an assembly still receiving pieces is not expired', () {
      final a = FragmentAssembler(expiry: const Duration(seconds: 10));
      final parts = piecesOf('g' * 1400, chunkSize: 200);
      var t = DateTime(2026);

      AssemblyOutcome? last;
      for (final p in parts) {
        last = a.add(p, now: t = t.add(const Duration(seconds: 9)));
      }
      expect(last!.status, AssemblyStatus.complete,
          reason: 'steady progress keeps it alive');
    });
  });

  test('clear releases everything', () {
    final a = FragmentAssembler();
    a.add(piecesOf('h' * 900)[0]);
    expect(a.inFlight, 1);
    a.clear();
    expect(a.inFlight, 0);
  });
}
