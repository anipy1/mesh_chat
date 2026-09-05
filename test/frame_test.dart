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
}

// Appended: hello frames carry the node id in-band, because Android cannot
// advertise an arbitrary local name and so identity cannot ride the
// advertisement.
