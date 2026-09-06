import 'dart:typed_data';

import 'package:mesh_chat/ble/frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round trips text', () {
    final f = Frame.text('hello mesh');
    final back = Frame.decode(f.encode())!;
    expect(back.envelopeVer, Frame.envelopeVersion);
    expect(back.ttl, 3);
    expect(back.msgId, f.msgId);
    expect(back.isReadableText, isTrue);
    expect(back.text, 'hello mesh');
  });

  test('header is 12 bytes and payload length is honoured', () {
    final f = Frame.text('abc'); // inner ver + type + 3 bytes
    expect(f.encode().length, Frame.headerLength + 5);
  });

  test('survives multi-byte utf8', () {
    final f = Frame.text('tere õhtust 🛰');
    expect(Frame.decode(f.encode())!.text, 'tere õhtust 🛰');
  });

  test('msgIds are distinct', () {
    final ids = {for (var i = 0; i < 500; i++) Frame.text('x').msgId};
    expect(ids.length, 500);
  });

  test('rejects bytes shorter than the header', () {
    expect(Frame.decode(Uint8List(11)), isNull);
  });

  test('rejects a truncated payload', () {
    final bytes = Frame.text('hello').encode();
    expect(Frame.decode(bytes.sublist(0, bytes.length - 1)), isNull);
  });

  // The property the whole envelope split exists for: a node running an older
  // build must still parse the frozen fields of a frame it cannot interpret,
  // because it has to relay it.
  test('unknown inner version still yields a relayable frame', () {
    final f = Frame.text('future');
    final bytes = f.encode();
    bytes[Frame.headerLength] = 99; // bump inner version

    final back = Frame.decode(bytes)!;
    expect(back.msgId, f.msgId, reason: 'dedup key must survive');
    expect(back.ttl, 3, reason: 'ttl must survive');
    expect(back.innerVer, 99);
    expect(back.isReadableText, isFalse, reason: 'must not be rendered');
  });

  test('unknown envelope version still yields a relayable frame', () {
    final f = Frame.text('further future');
    final bytes = f.encode();
    bytes[0] = 42;

    final back = Frame.decode(bytes)!;
    expect(back.envelopeVer, 42);
    expect(back.msgId, f.msgId);
    expect(back.ttl, 3);
  });

  test('unknown inner type is not rendered', () {
    final f = Frame.text('x');
    final bytes = f.encode();
    bytes[Frame.headerLength + 1] = 77; // unknown type
    expect(Frame.decode(bytes)!.isReadableText, isFalse);
  });

  test('hello carries the node id and is not renderable text', () {
    final f = Frame.hello('AB3D');
    final back = Frame.decode(f.encode())!;
    expect(back.isHello, isTrue);
    expect(back.text, 'AB3D');
    expect(back.isReadableText, isFalse, reason: 'never shown as a message');
  });

  test('text frames are not mistaken for hellos', () {
    expect(Frame.decode(Frame.text('AB3D').encode())!.isHello, isFalse);
  });

  test('hello uses ttl 1 so it is never relayed', () {
    expect(Frame.decode(Frame.hello('AB3D').encode())!.ttl, 1);
  });

  group('forwarding', () {
    test('decrements ttl and leaves everything else identical', () {
      final original = Frame.text('hop me').encode();
      final fwd = Frame.forwarded(original)!;
      expect(fwd[1], original[1] - 1);
      // Every byte except the ttl must be untouched.
      for (var i = 0; i < original.length; i++) {
        if (i == 1) continue;
        expect(fwd[i], original[i], reason: 'byte $i changed');
      }
      expect(Frame.decode(fwd)!.msgId, Frame.decode(original)!.msgId);
      expect(Frame.decode(fwd)!.text, 'hop me');
    });

    test('is terminal at ttl 1', () {
      final f = Frame.text('x', ttl: 1).encode();
      expect(Frame.forwarded(f), isNull);
    });

    test('hello is never forwardable', () {
      expect(Frame.forwarded(Frame.hello('AB3D').encode()), isNull);
    });

    // The point of the frozen envelope: a relay forwards payloads it cannot
    // read, without needing to understand or re-serialise them.
    test('forwards an unreadable payload byte-for-byte', () {
      final bytes = Frame.text('future thing').encode();
      bytes[Frame.headerLength] = 99; // unknown inner version
      bytes[Frame.headerLength + 1] = 77; // unknown inner type

      final fwd = Frame.forwarded(bytes)!;
      final back = Frame.decode(fwd)!;
      expect(back.isReadableText, isFalse);
      expect(back.innerVer, 99);
      expect(back.type, 77);
      expect(back.payload, Frame.decode(bytes)!.payload);
    });

    test('ttl 3 survives exactly two hops', () {
      var bytes = Frame.text('two hops').encode();
      expect(Frame.decode(bytes)!.ttl, 3);
      bytes = Frame.forwarded(bytes)!;
      expect(Frame.decode(bytes)!.ttl, 2);
      bytes = Frame.forwarded(bytes)!;
      expect(Frame.decode(bytes)!.ttl, 1);
      expect(Frame.forwarded(bytes), isNull);
    });
  });

  group('announce', () {
    const id = '0123456789abcdef';

    test('round trips', () {
      final parsed = Announce.parse(Frame.decode(Frame.announce(id).encode())!);
      expect(parsed!.peerId, id);
    });

    test('is tiny, because it repeats forever', () {
      expect(Frame.announce(id).encode().length, 22);
    });

    test('floods with the normal hop budget', () {
      // It has to reach past the first hop, which is the entire point.
      expect(Frame.announce(id).ttl, Frame.defaultTtl);
      expect(Frame.forwarded(Frame.announce(id).encode()), isNotNull);
    });

    test('carries its own label', () {
      final parsed = Announce.parse(Frame.announce(id))!;
      expect(parsed.label.length, 4);
    });

    test('is not mistaken for anything else', () {
      final f = Frame.announce(id);
      expect(f.isReadableText, isFalse);
      expect(f.isFragment, isFalse);
      expect(f.isHandshake, isFalse);
      expect(f.isSealed, isFalse);
      expect(f.isAnnounce, isTrue);
    });

    test('a text frame is not mistaken for an announce', () {
      expect(Announce.parse(Frame.text('hello')), isNull);
    });

    test('a payload too short to hold an id is refused', () {
      final truncated = Frame(
        envelopeVer: 1,
        ttl: 3,
        msgId: '0011223344556677',
        payload: Uint8List.fromList([1, Frame.typeAnnounce, 9, 9]),
      );
      expect(Announce.parse(truncated), isNull);
    });
  });

  group('directed frames', () {
    const dest = '0123456789abcdef';
    const src = 'fedcba9876543210';

    test('a handshake step round trips', () {
      final f = Frame.handshake(
        dest: dest,
        src: src,
        step: 1,
        body: Uint8List.fromList(List.filled(96, 7)),
      );
      final parsed = HandshakeMessage.parse(Frame.decode(f.encode())!)!;
      expect(parsed.dest, dest);
      expect(parsed.src, src);
      expect(parsed.step, 1);
      expect(parsed.body.length, 96);
      expect(parsed.body.every((b) => b == 7), isTrue);
    });

    test('a sealed message round trips, counter included', () {
      final f = Frame.sealed(
        dest: dest,
        src: src,
        counter: 123456789,
        ciphertext: Uint8List.fromList(List.filled(40, 9)),
      );
      final parsed = SealedEnvelope.parse(Frame.decode(f.encode())!)!;
      expect(parsed.dest, dest);
      expect(parsed.src, src);
      expect(parsed.counter, 123456789);
      expect(parsed.ciphertext.length, 40);
    });

    test('every XX step fits one frame', () {
      // Measured at 32, 96 and 64 bytes. If a handshake ever needed
      // fragmenting, a lost piece would stall the session rather than one
      // message.
      for (final size in [32, 96, 64]) {
        final f = Frame.handshake(
          dest: dest,
          src: src,
          step: 0,
          body: Uint8List(size),
        );
        expect(f.encode().length, lessThanOrEqualTo(Frame.meshMtu));
      }
    });

    test('the sealed budget is what actually fits', () {
      final f = Frame.sealed(
        dest: dest,
        src: src,
        counter: 0,
        // Plaintext budget plus the tag the cipher adds.
        ciphertext: Uint8List(Frame.sealedPlaintextBudget + 16),
      );
      expect(f.encode().length, Frame.meshMtu);
    });

    test('a directed frame is not mistaken for text or a fragment', () {
      final f = Frame.handshake(
        dest: dest,
        src: src,
        step: 0,
        body: Uint8List(32),
      );
      expect(f.isReadableText, isFalse);
      expect(f.isFragment, isFalse);
      expect(f.isHandshake, isTrue);
      expect(FragmentPart.parse(f), isNull);
      expect(SealedEnvelope.parse(f), isNull);
    });

    test('the label comes out of the peer id', () {
      // So a hello carrying an id has carried the label too.
      final f = Frame.handshake(
        dest: dest,
        src: src,
        step: 0,
        body: Uint8List(32),
      );
      final parsed = HandshakeMessage.parse(f)!;
      expect(parsed.srcLabel.length, 4);
      expect(RegExp(r'^[A-HJ-NP-Z2-9]{4}$').hasMatch(parsed.srcLabel), isTrue);
    });

    test('a peer id that is not 16 hex characters is refused', () {
      expect(
        () => Frame.handshake(
          dest: 'short',
          src: src,
          step: 0,
          body: Uint8List(32),
        ),
        throwsArgumentError,
      );
      expect(
        () => Frame.sealed(
          dest: dest,
          src: 'zzzzzzzzzzzzzzzz',
          counter: 0,
          ciphertext: Uint8List(32),
        ),
        throwsArgumentError,
      );
    });

    group('refuses nonsense before allocating anything', () {
      test('a step beyond the pattern', () {
        final f = Frame.handshake(
          dest: dest,
          src: src,
          step: 0,
          body: Uint8List(32),
        );
        f.payload[18] = 9;
        expect(HandshakeMessage.parse(f), isNull);
      });

      test('an empty handshake body', () {
        expect(
          HandshakeMessage.parse(
            Frame.handshake(
              dest: dest,
              src: src,
              step: 0,
              body: Uint8List(0),
            ),
          ),
          isNull,
        );
      });

      test('a frame addressed to its own sender', () {
        expect(
          HandshakeMessage.parse(
            Frame.handshake(
              dest: dest,
              src: dest,
              step: 0,
              body: Uint8List(32),
            ),
          ),
          isNull,
        );
      });

      test('a ciphertext too short to hold a tag', () {
        expect(
          SealedEnvelope.parse(
            Frame.sealed(
              dest: dest,
              src: src,
              counter: 0,
              ciphertext: Uint8List(8),
            ),
          ),
          isNull,
        );
      });

      test('a payload too short to hold the header', () {
        final truncated = Frame(
          envelopeVer: 1,
          ttl: 3,
          msgId: '0011223344556677',
          payload: Uint8List.fromList([1, Frame.typeSealed, 1, 2, 3]),
        );
        expect(SealedEnvelope.parse(truncated), isNull);
        expect(HandshakeMessage.parse(truncated), isNull);
      });
    });
  });

  group('fragmentation', () {
    Uint8List rejoin(List<Frame> parts) {
      final out = <int>[];
      for (final f in parts) {
        out.addAll(FragmentPart.parse(f)!.chunk);
      }
      return Uint8List.fromList(out);
    }

    test('splits and rejoins to the original bytes', () {
      final original = Frame.text('x' * 1500).encode();
      final parts = Frame.split(original, chunkSize: 400, ttl: 3)!;
      expect(parts.length, 4);
      expect(rejoin(parts), original);
      expect(Frame.decode(rejoin(parts))!.text, 'x' * 1500);
    });

    test('every piece is an ordinary frame with its own msgId', () {
      final parts =
          Frame.split(Frame.text('y' * 900).encode(), chunkSize: 300, ttl: 3)!;
      expect(parts.map((f) => f.msgId).toSet().length, parts.length);
      // and they all share one fragment id
      expect(parts.map((f) => FragmentPart.parse(f)!.id).toSet().length, 1);
    });

    test('pieces carry the ttl so relays forward them normally', () {
      final parts =
          Frame.split(Frame.text('z' * 500).encode(), chunkSize: 200, ttl: 2)!;
      for (final f in parts) {
        expect(f.ttl, 2);
        expect(Frame.forwarded(f.encode()), isNotNull);
      }
    });

    test('index and total are correct across the set', () {
      final parts =
          Frame.split(Frame.text('a' * 1000).encode(), chunkSize: 256, ttl: 3)!;
      for (var i = 0; i < parts.length; i++) {
        final part = FragmentPart.parse(parts[i])!;
        expect(part.index, i);
        expect(part.total, parts.length);
      }
    });

    test('a piece sized for the mesh fits inside the mesh mtu', () {
      // The property the whole design rests on: a relay forwards a piece
      // untouched, so every piece has to be small enough for any link in the
      // mesh, not just the one it was sent on.
      const chunkSize =
          Frame.meshMtu - Frame.headerLength - 2 - Frame.fragmentHeaderLength;
      final parts = Frame.split(
        Frame.text('z' * 4000).encode(),
        chunkSize: chunkSize,
        ttl: 3,
      )!;
      expect(parts.length, greaterThan(1));
      for (final piece in parts) {
        expect(piece.encode().length, lessThanOrEqualTo(Frame.meshMtu));
      }
    });

    test('a forwarded piece does not grow past the mesh mtu', () {
      // Relaying rewrites the ttl in place, so a piece that fitted on the way
      // in must still fit on the way out.
      const chunkSize =
          Frame.meshMtu - Frame.headerLength - 2 - Frame.fragmentHeaderLength;
      final parts = Frame.split(
        Frame.text('w' * 2000).encode(),
        chunkSize: chunkSize,
        ttl: 3,
      )!;
      for (final piece in parts) {
        final forwarded = Frame.forwarded(piece.encode())!;
        expect(forwarded.length, lessThanOrEqualTo(Frame.meshMtu));
      }
    });

    test('refuses to split into more than maxFragments', () {
      final big = Frame.text('b' * 100000).encode();
      expect(Frame.split(big, chunkSize: 64, ttl: 3), isNull);
    });

    test('a single small chunk still produces one valid piece', () {
      final one = Frame.text('hi').encode();
      final parts = Frame.split(one, chunkSize: 500, ttl: 3)!;
      expect(parts.length, 1);
      expect(rejoin(parts), one);
    });

    // Everything below is a peer lying to us. None of it should get as far as
    // allocating a buffer.
    // Absolute offsets into an encoded fragment frame:
    //   0..11  envelope (Frame.headerLength)
    //   12     inner version
    //   13     inner type
    //   14..21 fragment id
    //   22..23 index
    //   24..25 total
    const indexOffset = Frame.headerLength + 2 + 8;
    const totalOffset = Frame.headerLength + 2 + 10;

    Uint8List onePiece() => Frame.split(
          Frame.text('x' * 100).encode(),
          chunkSize: 50,
          ttl: 3,
        )!
            .first
            .encode();

    test('rejects a total of zero', () {
      final bytes = onePiece();
      bytes[totalOffset] = 0;
      bytes[totalOffset + 1] = 0;
      expect(FragmentPart.parse(Frame.decode(bytes)!), isNull);
    });

    test('rejects a total above maxFragments', () {
      final bytes = onePiece();
      bytes[totalOffset] = 0xFF; // 65535 pieces
      bytes[totalOffset + 1] = 0xFF;
      expect(FragmentPart.parse(Frame.decode(bytes)!), isNull);
    });

    test('rejects an index past the end', () {
      final bytes = onePiece();
      expect(FragmentPart.parse(Frame.decode(bytes)!)!.total, lessThan(99));
      bytes[indexOffset] = 0x00;
      bytes[indexOffset + 1] = 0x63; // index 99
      expect(FragmentPart.parse(Frame.decode(bytes)!), isNull);
    });

    test('rejects a payload too short to hold a header', () {
      final stunted = Frame(
        envelopeVer: Frame.envelopeVersion,
        ttl: 3,
        msgId: '0011223344556677',
        payload:
            Uint8List.fromList([Frame.innerVersion, Frame.typeFragment, 1]),
      );
      expect(FragmentPart.parse(Frame.decode(stunted.encode())!), isNull);
    });

    test('a text frame is not mistaken for a fragment', () {
      expect(FragmentPart.parse(Frame.text('hello')), isNull);
    });
  });
}

// Appended: hello frames carry the node id in-band, because Android cannot
// advertise an arbitrary local name and so identity cannot ride the
// advertisement.
