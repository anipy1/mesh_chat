import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'handshake_pattern.dart';

/// Noise_*_25519_ChaChaPoly_SHA256.
///
/// Written against the Noise spec revision 34 rather than taken from a library.
/// The Dart Noise packages on pub.dev have single digit like counts and two
/// digit download counts, which is not a base to put the security layer on.
/// Hand written cryptography is its own risk, so the whole point of this file
/// is the test beside it: it is checked against the official Noise vectors, and
/// anything here that disagrees with the spec fails loudly rather than quietly
/// producing plausible looking bytes.
///
/// Not implemented, because nothing here needs them: PSK modes, fallback
/// patterns, hybrid forward secrecy, and any cipher suite but this one.
class NoiseError implements Exception {
  NoiseError(this.message);

  final String message;

  @override
  String toString() => 'NoiseError: $message';
}

const int _hashLen = 32;
const int _keyLen = 32;
const int _tagLen = 16;
const int _dhLen = 32;

/// Nonce ceiling from the spec. Reaching it means something is very wrong.
const int _maxNonce = 0xFFFFFFFFFFFFFFFF;

/// AEAD keyed on a 32 byte key with a counter nonce.
///
/// The counter never repeats under one key, which is the entire security
/// requirement, so it only ever moves forwards and there is no way to set it.
class CipherState {
  CipherState._(this._key);

  /// A cipher with no key yet. Encrypt and decrypt pass data straight through,
  /// which is how the early handshake messages travel before there is any
  /// shared secret.
  factory CipherState.empty() => CipherState._(null);

  factory CipherState.withKey(List<int> key) {
    if (key.length != _keyLen) {
      throw NoiseError('key must be $_keyLen bytes, got ${key.length}');
    }
    return CipherState._(Uint8List.fromList(key));
  }

  static final _aead = Chacha20.poly1305Aead();

  Uint8List? _key;
  int _nonce = 0;

  bool get hasKey => _key != null;

  /// 12 byte nonce: four zero bytes then the counter, little endian.
  ///
  /// Little endian is easy to get wrong here and produces a working looking
  /// implementation that cannot talk to anyone else.
  static Uint8List _nonceBytes(int n) {
    final out = Uint8List(12);
    final view = ByteData.view(out.buffer);
    view.setUint64(4, n, Endian.little);
    return out;
  }

  Future<Uint8List> encryptWithAd(List<int> ad, List<int> plaintext) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(plaintext);
    if (_nonce == _maxNonce) throw NoiseError('nonce exhausted');

    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _nonceBytes(_nonce),
      aad: ad,
    );
    _nonce++;

    // Noise puts the tag immediately after the ciphertext.
    final out = Uint8List(box.cipherText.length + _tagLen);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Encrypts at a caller-chosen counter, leaving our own counter alone.
  ///
  /// Reusing a counter under one key destroys the security of the cipher
  /// completely, so nothing should call this directly. [NoiseTransport] owns a
  /// counter and is the only intended caller.
  Future<Uint8List> encryptWithAdAt(
    int nonce,
    List<int> ad,
    List<int> plaintext,
  ) async {
    final key = _key;
    if (key == null) throw NoiseError('transport cipher has no key');
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _nonceBytes(nonce),
      aad: ad,
    );
    final out = Uint8List(box.cipherText.length + _tagLen);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Decrypts at a counter the sender chose, leaving our own counter alone.
  ///
  /// Safe to call with an attacker-supplied nonce: a wrong one simply fails to
  /// authenticate. Replay is a separate problem, handled by [ReplayWindow].
  Future<Uint8List> decryptWithAdAt(
    int nonce,
    List<int> ad,
    List<int> ciphertext,
  ) async {
    final key = _key;
    if (key == null) throw NoiseError('transport cipher has no key');
    if (ciphertext.length < _tagLen) {
      throw NoiseError('ciphertext shorter than its tag');
    }
    final split = ciphertext.length - _tagLen;
    final box = SecretBox(
      ciphertext.sublist(0, split),
      nonce: _nonceBytes(nonce),
      mac: Mac(ciphertext.sublist(split)),
    );
    try {
      final clear = await _aead.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: ad,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw NoiseError('decryption failed');
    }
  }

  Future<Uint8List> decryptWithAd(List<int> ad, List<int> ciphertext) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(ciphertext);
    if (_nonce == _maxNonce) throw NoiseError('nonce exhausted');
    if (ciphertext.length < _tagLen) {
      throw NoiseError('ciphertext shorter than its tag');
    }

    final split = ciphertext.length - _tagLen;
    final box = SecretBox(
      ciphertext.sublist(0, split),
      nonce: _nonceBytes(_nonce),
      mac: Mac(ciphertext.sublist(split)),
    );

    late final List<int> clear;
    try {
      clear = await _aead.decrypt(box, secretKey: SecretKey(key), aad: ad);
    } on SecretBoxAuthenticationError {
      // Do not advance the nonce on a failed decrypt. A peer that can make us
      // skip nonces can desynchronise the session at will.
      throw NoiseError('decryption failed');
    }
    _nonce++;
    return Uint8List.fromList(clear);
  }
}

/// The running hash and chaining key that tie a handshake together.
class SymmetricState {
  SymmetricState._(this._ck, this._h, this._cipher);

  factory SymmetricState(String protocolName) {
    final name = Uint8List.fromList(protocolName.codeUnits);
    final Uint8List h;
    if (name.length <= _hashLen) {
      // Short names are padded rather than hashed. Getting this backwards is a
      // classic way to produce an implementation that only talks to itself.
      h = Uint8List(_hashLen)..setRange(0, name.length, name);
    } else {
      h = _sha256Sync(name);
    }
    return SymmetricState._(
      Uint8List.fromList(h),
      h,
      CipherState.empty(),
    );
  }

  Uint8List _ck;
  Uint8List _h;
  CipherState _cipher;

  Uint8List get handshakeHash => Uint8List.fromList(_h);

  void mixHash(List<int> data) {
    _h = _sha256Sync(Uint8List.fromList([..._h, ...data]));
  }

  Future<void> mixKey(List<int> inputKeyMaterial) async {
    final out = await _hkdf(_ck, inputKeyMaterial, 2);
    _ck = out[0];
    _cipher = CipherState.withKey(out[1]);
  }

  /// Only used by PSK modes, which this does not implement, but the vectors for
  /// deferred patterns exercise the same code path through [mixKey].
  Future<void> mixKeyAndHash(List<int> inputKeyMaterial) async {
    final out = await _hkdf(_ck, inputKeyMaterial, 3);
    _ck = out[0];
    mixHash(out[1]);
    _cipher = CipherState.withKey(out[2]);
  }

  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    final ciphertext = await _cipher.encryptWithAd(_h, plaintext);
    mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> decryptAndHash(List<int> ciphertext) async {
    // The hash has to move on with the ciphertext, so it is captured before
    // decrypting rather than after.
    final plaintext = await _cipher.decryptWithAd(_h, ciphertext);
    mixHash(ciphertext);
    return plaintext;
  }

  /// The two transport ciphers. First is for the initiator to send with.
  Future<(CipherState, CipherState)> split() async {
    final out = await _hkdf(_ck, const <int>[], 2);
    return (CipherState.withKey(out[0]), CipherState.withKey(out[1]));
  }
}

/// One side of a handshake in progress.
class HandshakeState {
  HandshakeState._({
    required this.initiator,
    required SymmetricState symmetric,
    required List<List<Token>> messages,
    required SimpleKeyPair? staticKeyPair,
    required Uint8List? staticPublicKey,
    required SimpleKeyPair? ephemeralKeyPair,
    required Uint8List? ephemeralPublicKey,
    required Uint8List? remoteStatic,
    required Uint8List? remoteEphemeral,
  })  : _symmetric = symmetric,
        _messages = messages,
        _s = staticKeyPair,
        _sPub = staticPublicKey,
        _e = ephemeralKeyPair,
        _ePub = ephemeralPublicKey,
        _rs = remoteStatic,
        _re = remoteEphemeral;

  /// Starts a handshake.
  ///
  /// [fixedEphemeral] exists so the official vectors, which pin the ephemeral
  /// keys, can be replayed exactly. Nothing but a test should ever pass it: a
  /// reused ephemeral destroys forward secrecy, which is most of the reason to
  /// run a handshake at all.
  static Future<HandshakeState> start({
    required HandshakePattern pattern,
    required bool initiator,
    SimpleKeyPair? staticKeyPair,
    Uint8List? remoteStaticKey,
    List<int> prologue = const <int>[],
    String cipherSuite = '25519_ChaChaPoly_SHA256',
    List<int>? fixedEphemeral,
  }) async {
    final symmetric = SymmetricState('Noise_${pattern.name}_$cipherSuite');
    symmetric.mixHash(prologue);

    Uint8List? staticPublic;
    if (staticKeyPair != null) {
      staticPublic = Uint8List.fromList(
        (await staticKeyPair.extractPublicKey()).bytes,
      );
    }

    SimpleKeyPair? ephemeral;
    Uint8List? ephemeralPublic;
    if (fixedEphemeral != null) {
      ephemeral = await X25519().newKeyPairFromSeed(fixedEphemeral);
      ephemeralPublic = Uint8List.fromList(
        (await ephemeral.extractPublicKey()).bytes,
      );
    }

    // Pre-message keys are hashed in initiator-first order by both sides, not
    // in local-then-remote order.
    for (final token in pattern.initiatorPreMessage) {
      final key = initiator
          ? (token == Token.s ? staticPublic : ephemeralPublic)
          : (token == Token.s ? remoteStaticKey : null);
      if (key == null) throw NoiseError('missing initiator pre-message key');
      symmetric.mixHash(key);
    }
    for (final token in pattern.responderPreMessage) {
      final key = initiator
          ? (token == Token.s ? remoteStaticKey : null)
          : (token == Token.s ? staticPublic : ephemeralPublic);
      if (key == null) throw NoiseError('missing responder pre-message key');
      symmetric.mixHash(key);
    }

    return HandshakeState._(
      initiator: initiator,
      symmetric: symmetric,
      messages: pattern.messages,
      staticKeyPair: staticKeyPair,
      staticPublicKey: staticPublic,
      ephemeralKeyPair: ephemeral,
      ephemeralPublicKey: ephemeralPublic,
      remoteStatic: remoteStaticKey,
      remoteEphemeral: null,
    );
  }

  final bool initiator;
  final SymmetricState _symmetric;
  final List<List<Token>> _messages;

  final SimpleKeyPair? _s;
  final Uint8List? _sPub;
  SimpleKeyPair? _e;
  Uint8List? _ePub;
  Uint8List? _rs;
  Uint8List? _re;

  int _index = 0;

  /// True once every message in the pattern has been written or read.
  bool get isComplete => _index >= _messages.length;

  /// Whose turn it is to write.
  bool get myTurn => isComplete ? false : (_index.isEven == initiator);

  /// The peer's static public key, once the pattern has revealed it.
  Uint8List? get remoteStaticKey =>
      _rs == null ? null : Uint8List.fromList(_rs!);

  Uint8List get handshakeHash => _symmetric.handshakeHash;

  Future<Uint8List> writeMessage([List<int> payload = const <int>[]]) async {
    if (isComplete) throw NoiseError('handshake already finished');
    if (!myTurn) throw NoiseError('not our turn to write');

    final out = <int>[];
    for (final token in _messages[_index]) {
      switch (token) {
        case Token.e:
          if (_e == null) {
            _e = await X25519().newKeyPair();
            _ePub = Uint8List.fromList((await _e!.extractPublicKey()).bytes);
          }
          out.addAll(_ePub!);
          _symmetric.mixHash(_ePub!);
        case Token.s:
          final s = _sPub;
          if (s == null) throw NoiseError('pattern needs a static key');
          out.addAll(await _symmetric.encryptAndHash(s));
        case Token.ee:
        case Token.es:
        case Token.se:
        case Token.ss:
          await _symmetric.mixKey(await _dhFor(token));
      }
    }
    out.addAll(await _symmetric.encryptAndHash(payload));
    _index++;
    return Uint8List.fromList(out);
  }

  Future<Uint8List> readMessage(List<int> message) async {
    if (isComplete) throw NoiseError('handshake already finished');
    if (myTurn) throw NoiseError('not our turn to read');

    var rest = message;
    for (final token in _messages[_index]) {
      switch (token) {
        case Token.e:
          if (rest.length < _dhLen) throw NoiseError('message truncated at e');
          _re = Uint8List.fromList(rest.sublist(0, _dhLen));
          _symmetric.mixHash(_re!);
          rest = rest.sublist(_dhLen);
        case Token.s:
          // The static key is encrypted once there is a key to encrypt with,
          // which is why the length depends on the cipher's state.
          final size = _symmetric._cipher.hasKey ? _dhLen + _tagLen : _dhLen;
          if (rest.length < size) throw NoiseError('message truncated at s');
          _rs = await _symmetric.decryptAndHash(rest.sublist(0, size));
          rest = rest.sublist(size);
        case Token.ee:
        case Token.es:
        case Token.se:
        case Token.ss:
          await _symmetric.mixKey(await _dhFor(token));
      }
    }
    final payload = await _symmetric.decryptAndHash(rest);
    _index++;
    return payload;
  }

  /// The transport ciphers, once the handshake is finished.
  ///
  /// Returns them as (ours, theirs) so neither side has to remember which of
  /// the two HKDF outputs belongs to whom.
  Future<(CipherState send, CipherState receive)> split() async {
    if (!isComplete) throw NoiseError('handshake is not finished');
    final (first, second) = await _symmetric.split();
    return initiator ? (first, second) : (second, first);
  }

  /// Resolves a DH token to the right pair of keys.
  ///
  /// The token names the initiator's key first and the responder's second, so
  /// which of ours it means depends on which side we are. `es` is the
  /// initiator's ephemeral with the responder's static, always, and it is read
  /// the same way by both sides.
  Future<List<int>> _dhFor(Token token) async {
    final (SimpleKeyPair? local, Uint8List? remote) = switch (token) {
      Token.ee => (_e, _re),
      Token.ss => (_s, _rs),
      Token.es => initiator ? (_e, _rs) : (_s, _re),
      Token.se => initiator ? (_s, _re) : (_e, _rs),
      _ => (null, null),
    };
    if (local == null || remote == null) {
      throw NoiseError('missing key for ${token.name}');
    }
    final shared = await X25519().sharedSecretKey(
      keyPair: local,
      remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
    );
    return shared.extractBytes();
  }
}

// ---------------------------------------------------------------- primitives

/// Noise's HKDF, written the way the spec writes it.
///
/// This is RFC 5869 with the chaining key as salt and an empty info, but it is
/// spelled out in HMAC directly rather than routed through a general HKDF, so
/// there is no question about which argument is the salt and which is the key
/// material. That confusion produces an implementation that passes its own
/// round trip test and cannot talk to anything else.
Future<List<Uint8List>> _hkdf(
  List<int> chainingKey,
  List<int> inputKeyMaterial,
  int outputs,
) async {
  final tempKey = await _hmac(chainingKey, inputKeyMaterial);
  final out1 = await _hmac(tempKey, const [0x01]);
  if (outputs == 1) return [out1];
  final out2 = await _hmac(tempKey, [...out1, 0x02]);
  if (outputs == 2) return [out1, out2];
  final out3 = await _hmac(tempKey, [...out2, 0x03]);
  return [out1, out2, out3];
}

Future<Uint8List> _hmac(List<int> key, List<int> data) async {
  final mac = await Hmac.sha256().calculateMac(
    data,
    secretKey: SecretKey(key),
  );
  return Uint8List.fromList(mac.bytes);
}

/// SHA-256 over a byte range.
///
/// The synchronous DartSha256 is used rather than the async Sha256 because
/// mixHash is called from inside token loops where an await per call would make
/// the ordering harder to follow for no benefit.
Uint8List _sha256Sync(List<int> data) {
  return Uint8List.fromList(const DartSha256().hashSync(data).bytes);
}
