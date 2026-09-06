import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_chat/ble/outbox.dart';

void main() {
  group('waiting', () {
    test('holds a message until it is taken', () {
      final box = Outbox();
      box.add('peerA', 'hello');
      expect(box.pendingFor('peerA'), 1);
      expect(box.take('peerA'), ['hello']);
      expect(box.pendingFor('peerA'), 0);
    });

    test('keeps messages in the order they were written', () {
      final box = Outbox();
      box.add('peerA', 'one');
      box.add('peerA', 'two');
      box.add('peerA', 'three');
      expect(box.take('peerA'), ['one', 'two', 'three']);
    });

    test('keeps peers apart', () {
      final box = Outbox();
      box.add('peerA', 'for A');
      box.add('peerB', 'for B');
      expect(box.take('peerA'), ['for A']);
      expect(box.take('peerB'), ['for B']);
    });

    test('taking from a peer with nothing waiting is empty, not an error', () {
      expect(Outbox().take('nobody'), isEmpty);
    });

    test('taking hands over and forgets in one step', () {
      // Nothing in this mesh acknowledges anything, so "sent" is the only
      // signal there is. Holding a copy back would mean sending twice.
      final box = Outbox();
      box.add('peerA', 'once');
      expect(box.take('peerA'), ['once']);
      expect(box.take('peerA'), isEmpty);
    });
  });

  group('limits', () {
    test('drops the oldest message past the per peer cap', () {
      final box = Outbox(maxPerPeer: 3);
      for (final text in ['one', 'two', 'three', 'four']) {
        box.add('peerA', text);
      }
      expect(box.take('peerA'), ['two', 'three', 'four']);
    });

    test('drops the least recently written peer past the peer cap', () {
      var now = DateTime(2026, 1, 1, 12);
      final box = Outbox(maxPeers: 2, clock: () => now);

      box.add('oldest', 'a');
      now = now.add(const Duration(minutes: 1));
      box.add('middle', 'b');
      now = now.add(const Duration(minutes: 1));
      box.add('newest', 'c');

      expect(box.peerCount, 2);
      expect(box.pendingFor('oldest'), 0);
      expect(box.pendingFor('middle'), 1);
      expect(box.pendingFor('newest'), 1);
    });

    test('writing to a peer again keeps it from being dropped', () {
      // A peer is as recent as its newest message, so an ongoing conversation
      // survives while a stale one goes.
      var now = DateTime(2026, 1, 1, 12);
      final box = Outbox(maxPeers: 2, clock: () => now);

      box.add('ongoing', 'first');
      now = now.add(const Duration(minutes: 1));
      box.add('stale', 'only');
      now = now.add(const Duration(minutes: 1));
      box.add('ongoing', 'second');
      now = now.add(const Duration(minutes: 1));
      box.add('newcomer', 'hi');

      expect(box.pendingFor('ongoing'), 2);
      expect(box.pendingFor('stale'), 0);
      expect(box.pendingFor('newcomer'), 1);
    });
  });

  group('expiry', () {
    test('gives up on a message that waited too long', () {
      var now = DateTime(2026, 1, 1, 12);
      final box = Outbox(ttl: const Duration(hours: 1), clock: () => now);
      box.add('peerA', 'stale');

      now = now.add(const Duration(minutes: 30));
      expect(box.expire(), isEmpty);
      expect(box.pendingFor('peerA'), 1);

      now = now.add(const Duration(minutes: 45));
      expect(box.expire(), {'peerA': 1});
      expect(box.pendingFor('peerA'), 0);
      expect(box.peerCount, 0);
    });

    test('only the old messages go, not the whole conversation', () {
      var now = DateTime(2026, 1, 1, 12);
      final box = Outbox(ttl: const Duration(hours: 1), clock: () => now);
      box.add('peerA', 'old');

      now = now.add(const Duration(minutes: 50));
      box.add('peerA', 'recent');

      now = now.add(const Duration(minutes: 20));
      expect(box.expire(), {'peerA': 1});
      expect(box.take('peerA'), ['recent']);
    });

    test('a peer with nothing left stops being tracked', () {
      var now = DateTime(2026, 1, 1, 12);
      final box = Outbox(ttl: const Duration(minutes: 5), clock: () => now);
      box.add('peerA', 'x');
      now = now.add(const Duration(minutes: 10));
      box.expire();
      expect(box.peers, isEmpty);
    });
  });

  group('counting', () {
    test('reports what is waiting overall', () {
      final box = Outbox();
      box.add('peerA', 'one');
      box.add('peerA', 'two');
      box.add('peerB', 'three');
      expect(box.peerCount, 2);
      expect(box.messageCount, 3);
    });
  });
}
