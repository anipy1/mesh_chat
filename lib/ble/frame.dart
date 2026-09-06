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
  static const typeFragment = 3;
  static const typeHandshake = 4;
  static const typeSealed = 5;
  static const typeAnnounce = 6;

  /// Hop budget a fresh message starts with. A receiver turns the ttl it
  /// sees back into a hop count: hops = defaultTtl - ttl.
  static const defaultTtl = 3;

  /// Bytes of fragment header inside the payload: 8 id, 2 index, 2 total.
  static const fragmentHeaderLength = 12;

  /// Ceiling on how many pieces one message may become. Anything above this is
  /// refused rather than sent, so one message cannot occupy the radio
  /// indefinitely. Raise it when there is a reason to.
  static const maxFragments = 64;

  /// Bytes of addressing inside a directed payload: 8 destination, 8 source.
  ///
  /// Addressing lives in the payload rather than the envelope because the
  /// envelope is frozen and a relay has no business reading it. A relay floods
  /// these exactly like anything else: it cannot tell them apart, and it does
  /// not need to.
  ///
  /// Both ids are in the clear. Sealing hides what is said, not who is saying it
  /// to whom, and pretending otherwise would be worse than saying so.
  static const addressLength = 16;

  /// Addressing plus the handshake step number.
  static const handshakeHeaderLength = addressLength + 1;

  /// Just a peer id.
  static const announceLength = 8;

  /// Addressing plus the 8 byte transport counter.
  static const sealedHeaderLength = addressLength + 8;

  /// Largest plaintext that still fits one unfragmented sealed frame.
  static const sealedPlaintextBudget =
      meshMtu - headerLength - 2 - sealedHeaderLength - 16;

  /// The largest frame this mesh will put on the air, in bytes.
  ///
  /// Fragmentation has to be sized against the mesh, not against the sender's
  /// own links. A relay forwards a piece untouched, on purpose, so a piece
  /// sized to fit our neighbour can still be too large for the hop after it,
  /// and a relay cannot split one without reassembling first. Sizing every
  /// piece to a floor any link can carry is what lets fragmentation and
  /// relaying work together at all.
  ///
  /// 185 is the conservative figure both platforms are safe at. Our own phones
  /// negotiated well beyond it, 512 usable in both directions with one link at
  /// 371, so this can be raised. It should be raised on evidence from more
  /// devices than three, though, because the cost of being wrong is a message
  /// that crosses one hop and dies at the next.
  static const meshMtu = 185;

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

  bool get isFragment => innerVer == innerVersion && type == typeFragment;

  bool get isHandshake => innerVer == innerVersion && type == typeHandshake;

  bool get isSealed => innerVer == innerVersion && type == typeSealed;

  bool get isAnnounce => innerVer == innerVersion && type == typeAnnounce;

  static final _rnd = Random.secure();

  /// Announces our node id on one link. The advertised name cannot carry this:
  /// Android's AdvertiseData has no arbitrary local-name field, only
  /// setIncludeDeviceName(bool), so a custom string is silently dropped there.
  /// Identity therefore has to be exchanged in-band.
  factory Frame.hello(String nodeId) => _build(typeHello, nodeId, 1);

  factory Frame.text(String message, {int ttl = defaultTtl}) =>
      _build(typeText, message, ttl);

  /// Says "this peer id exists and is alive", to the whole mesh.
  ///
  /// A hello does the same job for one link and is never relayed, which left a
  /// gap: a node could only ever start a session with a peer it was directly
  /// adjacent to. Sessions relay fine once they exist, but nothing was
  /// discovering the peers that were never neighbours in the first place.
  ///
  /// Ordinary relayable traffic, so it floods, dedupes and damps like anything
  /// else, and costs 22 bytes.
  ///
  /// It does put every peer id on the air for anyone in range to collect,
  /// rather than only telling immediate neighbours. That is a real cost and it
  /// is the same trade bitchat makes: without it the mesh cannot introduce
  /// peers to each other at all.
  factory Frame.announce(String peerId, {int ttl = defaultTtl}) {
    final payload = Uint8List(2 + announceLength);
    payload[0] = innerVersion;
    payload[1] = typeAnnounce;
    _writeId(payload, 2, peerId);
    return Frame(
      envelopeVer: envelopeVersion,
      ttl: ttl,
      msgId: _newMsgId(),
      payload: payload,
    );
  }

  /// One step of a Noise handshake, addressed to a particular peer.
  ///
  /// Relayable, unlike a hello. A hello identifies a link and dies with it, but
  /// a session belongs to a peer and has to survive the link churn we measured:
  /// legs come and go constantly, and a peer can stop being a neighbour without
  /// stopping being reachable.
  ///
  /// [step] is carried rather than inferred so a restarted handshake can be
  /// recognised. Over a flooding mesh a step can be lost or arrive twice, and a
  /// receiver that guessed the step from its own state would deadlock.
  factory Frame.handshake({
    required String dest,
    required String src,
    required int step,
    required Uint8List body,
    int ttl = defaultTtl,
  }) {
    final payload = Uint8List(2 + handshakeHeaderLength + body.length);
    payload[0] = innerVersion;
    payload[1] = typeHandshake;
    _writeId(payload, 2, dest);
    _writeId(payload, 10, src);
    payload[18] = step;
    payload.setRange(2 + handshakeHeaderLength, payload.length, body);
    return Frame(
      envelopeVer: envelopeVersion,
      ttl: ttl,
      msgId: _newMsgId(),
      payload: payload,
    );
  }

  /// A message only [dest] can read.
  ///
  /// The counter travels with it because this mesh delivers out of order, and
  /// Noise's implicit transport counter cannot survive that.
  factory Frame.sealed({
    required String dest,
    required String src,
    required int counter,
    required Uint8List ciphertext,
    int ttl = defaultTtl,
  }) {
    final payload = Uint8List(2 + sealedHeaderLength + ciphertext.length);
    payload[0] = innerVersion;
    payload[1] = typeSealed;
    _writeId(payload, 2, dest);
    _writeId(payload, 10, src);
    ByteData.view(payload.buffer).setUint64(18, counter, Endian.big);
    payload.setRange(2 + sealedHeaderLength, payload.length, ciphertext);
    return Frame(
      envelopeVer: envelopeVersion,
      ttl: ttl,
      msgId: _newMsgId(),
      payload: payload,
    );
  }

  /// Writes a 16 character hex id as 8 bytes at [offset].
  static void _writeId(Uint8List out, int offset, String hexId) {
    if (hexId.length != 16) {
      throw ArgumentError('peer id must be 16 hex characters, got "$hexId"');
    }
    for (var i = 0; i < 8; i++) {
      final b = int.tryParse(hexId.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) throw ArgumentError('peer id is not hex: "$hexId"');
      out[offset + i] = b;
    }
  }

  static String _readId(Uint8List p, int offset) {
    final out = StringBuffer();
    for (var i = 0; i < 8; i++) {
      out.write(p[offset + i].toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// One piece of a larger frame.
  ///
  /// The chunk is a slice of the *original complete frame*, envelope included,
  /// so gluing the pieces back together gives something [decode] understands. A
  /// relay never needs to know any of this: a fragment is an ordinary frame with
  /// its own msgId and ttl, so it floods and dedupes like anything else.
  factory Frame.fragment({
    required String fragmentId,
    required int index,
    required int total,
    required Uint8List chunk,
    required int ttl,
  }) {
    final payload = Uint8List(2 + fragmentHeaderLength + chunk.length);
    payload[0] = innerVersion;
    payload[1] = typeFragment;
    for (var i = 0; i < 8; i++) {
      payload[2 + i] = int.parse(
        fragmentId.substring(i * 2, i * 2 + 2),
        radix: 16,
      );
    }
    final view = ByteData.view(payload.buffer);
    view.setUint16(10, index, Endian.big);
    view.setUint16(12, total, Endian.big);
    payload.setRange(2 + fragmentHeaderLength, payload.length, chunk);

    return Frame(
      envelopeVer: envelopeVersion,
      ttl: ttl,
      msgId: _newMsgId(),
      payload: payload,
    );
  }

  /// Splits [frameBytes] into pieces that each carry at most [chunkSize] bytes.
  /// Returns null when that would need more than [maxFragments].
  static List<Frame>? split(
    Uint8List frameBytes, {
    required int chunkSize,
    required int ttl,
  }) {
    if (chunkSize <= 0 || frameBytes.isEmpty) return null;
    final total = (frameBytes.length + chunkSize - 1) ~/ chunkSize;
    if (total > maxFragments) return null;

    final id = _newMsgId();
    return [
      for (var i = 0; i < total; i++)
        Frame.fragment(
          fragmentId: id,
          index: i,
          total: total,
          chunk: Uint8List.sublistView(
            frameBytes,
            i * chunkSize,
            ((i + 1) * chunkSize).clamp(0, frameBytes.length),
          ),
          ttl: ttl,
        ),
    ];
  }

  static Frame _build(int type, String message, int ttl) {
    final body = utf8.encode(message);
    final payload = Uint8List(2 + body.length)
      ..[0] = innerVersion
      ..[1] = type
      ..setRange(2, 2 + body.length, body);
    return Frame(
      envelopeVer: envelopeVersion,
      ttl: ttl,
      msgId: _newMsgId(),
      payload: payload,
    );
  }

  static String _newMsgId() {
    final id = List.generate(8, (_) => _rnd.nextInt(256));
    return id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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

/// The fragment header parsed out of a fragment frame's payload.
///
/// Everything is validated here, before a single byte is buffered. A peer that
/// claims 60000 pieces or an index past the end gets rejected at parse time
/// rather than after we have allocated something on its behalf.
/// A peer announcing itself, once it has been checked.
class Announce {
  const Announce(this.peerId);

  final String peerId;

  String get label => _labelOf(peerId);

  static Announce? parse(Frame frame) {
    if (!frame.isAnnounce) return null;
    final p = frame.payload;
    if (p.length < 2 + Frame.announceLength) return null;
    return Announce(Frame._readId(p, 2));
  }
}

/// A handshake step as it arrived, once it has been checked.
///
/// Everything is validated before anything is allocated. These frames come off
/// the radio from anyone at all, and a peer claiming a nonsense step or a short
/// body should cost us nothing.
class HandshakeMessage {
  const HandshakeMessage({
    required this.dest,
    required this.src,
    required this.step,
    required this.body,
  });

  /// Steps in an XX handshake. A step outside this range is refused.
  static const maxStep = 2;

  final String dest;
  final String src;
  final int step;
  final Uint8List body;

  String get srcLabel => _labelOf(src);

  static HandshakeMessage? parse(Frame frame) {
    if (!frame.isHandshake) return null;
    final p = frame.payload;
    if (p.length < 2 + Frame.handshakeHeaderLength) return null;

    final step = p[18];
    if (step > maxStep) return null;

    // An empty body is never a valid handshake step, and a self-addressed one
    // is either a bug or someone playing games.
    final body = Uint8List.sublistView(p, 2 + Frame.handshakeHeaderLength);
    if (body.isEmpty) return null;

    final dest = Frame._readId(p, 2);
    final src = Frame._readId(p, 10);
    if (dest == src) return null;

    return HandshakeMessage(dest: dest, src: src, step: step, body: body);
  }
}

/// A sealed message as it arrived, once it has been checked.
class SealedEnvelope {
  const SealedEnvelope({
    required this.dest,
    required this.src,
    required this.counter,
    required this.ciphertext,
  });

  final String dest;
  final String src;
  final int counter;
  final Uint8List ciphertext;

  String get srcLabel => _labelOf(src);

  static SealedEnvelope? parse(Frame frame) {
    if (!frame.isSealed) return null;
    final p = frame.payload;
    if (p.length < 2 + Frame.sealedHeaderLength) return null;

    // Shorter than a tag means there is no authenticated message in there at
    // all, whatever else it might be.
    final ciphertext = Uint8List.sublistView(p, 2 + Frame.sealedHeaderLength);
    if (ciphertext.length < 16) return null;

    final counter = ByteData.view(
      p.buffer,
      p.offsetInBytes,
    ).getUint64(18, Endian.big);
    if (counter < 0) return null;

    final dest = Frame._readId(p, 2);
    final src = Frame._readId(p, 10);
    if (dest == src) return null;

    return SealedEnvelope(
      dest: dest,
      src: src,
      counter: counter,
      ciphertext: ciphertext,
    );
  }
}

/// The four character label for a peer id.
///
/// Duplicated from NodeIdentity rather than imported, so the wire format has no
/// dependency on the identity module. The derivation is fixed by the format.
String _labelOf(String peerIdHex) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final out = StringBuffer();
  var acc = 0;
  var bits = 0;
  var i = 0;
  while (out.length < 4 && i + 1 < peerIdHex.length) {
    if (bits < 5) {
      final b = int.tryParse(peerIdHex.substring(i, i + 2), radix: 16);
      if (b == null) break;
      i += 2;
      acc = (acc << 8) | b;
      bits += 8;
    }
    bits -= 5;
    out.write(alphabet[(acc >> bits) & 0x1f]);
  }
  return out.toString();
}

class FragmentPart {
  const FragmentPart({
    required this.id,
    required this.index,
    required this.total,
    required this.chunk,
  });

  /// Groups the pieces of one message. 8 random bytes, as hex.
  final String id;
  final int index;
  final int total;
  final Uint8List chunk;

  static FragmentPart? parse(Frame frame) {
    if (!frame.isFragment) return null;
    final p = frame.payload;
    if (p.length < 2 + Frame.fragmentHeaderLength) return null;

    final view = ByteData.view(p.buffer, p.offsetInBytes);
    final index = view.getUint16(10, Endian.big);
    final total = view.getUint16(12, Endian.big);

    if (total < 1 || total > Frame.maxFragments) return null;
    if (index >= total) return null;

    final id =
        p.sublist(2, 10).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    return FragmentPart(
      id: id,
      index: index,
      total: total,
      chunk: Uint8List.sublistView(p, 2 + Frame.fragmentHeaderLength),
    );
  }

  String get shortId => id.substring(0, 6);
}
