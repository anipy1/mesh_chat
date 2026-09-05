import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Wire frame for the spike.
///
/// Split in two on purpose, because the real interop problem for this app is
/// not talking to other vendors -- it is a v1.0 device having to relay a v1.3
/// packet it cannot parse. So the outer envelope is frozen and a relay needs
/// only three things from it (msgId to dedupe, ttl to decrement, length to
/// frame), and everything that will actually evolve lives in the opaque
/// payload.
///
///   outer (FROZEN, 12 bytes) | ver:1 | ttl:1 | msgId:8 | payloadLen:2 |
///   payload (opaque)         | innerVer:1 | type:1 | bytes... |
///
/// Nothing else goes in the outer header. No sender id in particular -- that is
/// both a privacy leak to a passive radio and a thing we would later want to
/// change.
class Frame {
  static const envelopeVersion = 1;
  static const headerLength = 12;

  static const innerVersion = 1;
  static const typeText = 1;
  static const typeHello = 2;

  /// Hop budget a fresh message starts with. A receiver turns the ttl it
  /// sees back into a hop count: hops = defaultTtl - ttl.
  static const defaultTtl = 3;

  const Frame({
    required this.envelopeVer,
    required this.ttl,
    required this.msgId,
    required this.payload,
  });

  final int envelopeVer;
  final int ttl;
  final String msgId; // hex, 16 chars
  final Uint8List payload;

  /// Inner version, or null when the payload is too short to have one.
  int? get innerVer => payload.isEmpty ? null : payload[0];

  int? get type => payload.length < 2 ? null : payload[1];

  /// True when we understand the payload well enough to display it. A relay
  /// must forward frames where this is false -- that is the whole point of the
  /// split -- but it must not try to render them.
  bool get isReadableText => innerVer == innerVersion && type == typeText;

  String get text => utf8.decode(payload.sublist(2), allowMalformed: true);

  bool get isHello => innerVer == innerVersion && type == typeHello;

  static final _rnd = Random.secure();

  /// Announces our node id on one link. The advertised name cannot carry this:
  /// Android's AdvertiseData has no arbitrary local-name field, only
  /// setIncludeDeviceName(bool), so a custom string is silently dropped there.
  /// Identity therefore has to be exchanged in-band.
  factory Frame.hello(String nodeId) => _build(typeHello, nodeId, 1);

  factory Frame.text(String message, {int ttl = defaultTtl}) =>
      _build(typeText, message, ttl);

  static Frame _build(int type, String message, int ttl) {
    final body = utf8.encode(message);
    final payload = Uint8List(2 + body.length)
      ..[0] = innerVersion
      ..[1] = type
      ..setRange(2, 2 + body.length, body);
    final id = List.generate(8, (_) => _rnd.nextInt(256));
    final msgId = id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return Frame(
      envelopeVer: envelopeVersion,
      ttl: ttl,
      msgId: msgId,
      payload: payload,
    );
  }

  Uint8List encode() {
    final out = Uint8List(headerLength + payload.length);
    final view = ByteData.view(out.buffer);
    out[0] = envelopeVer;
    out[1] = ttl;
    for (var i = 0; i < 8; i++) {
      out[2 + i] = int.parse(msgId.substring(i * 2, i * 2 + 2), radix: 16);
    }
    view.setUint16(10, payload.length, Endian.big);
    out.setRange(headerLength, out.length, payload);
    return out;
  }

  /// Returns null when the bytes cannot be a frame at all. An *unknown*
  /// envelope version is not a decode failure here -- we still parse the frozen
  /// fields, because that is what makes a stale relay useful.
  static Frame? decode(Uint8List bytes) {
    if (bytes.length < headerLength) return null;
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final payloadLen = view.getUint16(10, Endian.big);
    if (bytes.length < headerLength + payloadLen) return null;
    final msgId = bytes
        .sublist(2, 10)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return Frame(
      envelopeVer: bytes[0],
      ttl: bytes[1],
      msgId: msgId,
      payload: Uint8List.sublistView(
        bytes,
        headerLength,
        headerLength + payloadLen,
      ),
    );
  }

  String get shortId => msgId.substring(0, 6);

  /// The same frame with `ttl` decremented, ready to forward. Returns null when
  /// the frame is terminal (`ttl <= 1`).
  ///
  /// Works on the *original bytes* rather than re-serialising. A relay must
  /// forward a payload it cannot interpret byte-for-byte, so the only thing it
  /// is allowed to touch is the one frozen header field it owns. Re-encoding
  /// would mean parsing, and parsing is exactly what a relay must not require.
  static Uint8List? forwarded(Uint8List bytes) {
    if (bytes.length < headerLength) return null;
    if (bytes[1] <= 1) return null;
    final out = Uint8List.fromList(bytes);
    out[1] = bytes[1] - 1;
    return out;
  }
}
