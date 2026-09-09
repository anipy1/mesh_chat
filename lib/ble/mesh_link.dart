import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'fragment_assembler.dart';
import 'frame.dart';
import 'outbox.dart';
import 'sealed_payload.dart';
import '../identity/identity_store.dart';
import '../identity/node_identity.dart';
import '../noise/noise_protocol.dart';
import '../noise/session_manager.dart';
import 'link_ids.dart';

enum LogLevel { info, tx, rx, warn, error }

class LogLine {
  LogLine(this.level, this.text) : time = DateTime.now();
  final DateTime time;
  final LogLevel level;
  final String text;

  String get stamp => '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';
}

class InboundMessage {
  InboundMessage({
    required this.frame,
    required this.via,
    required this.peer,
    this.sealedFrom,
    this.sealedText,
  });

  final Frame frame;
  final String via; // 'notify' (we are central) or 'write' (we are peripheral)
  final String peer;

  /// Set when this arrived sealed: the peer id it was proved to come from.
  ///
  /// Proved rather than claimed. The source field in the frame is just bytes
  /// anyone can write, but a sealed message only opens under a session that
  /// was authenticated to that peer's key.
  final String? sealedFrom;

  /// The decrypted text, when [sealedFrom] is set.
  final String? sealedText;

  bool get isSealed => sealedFrom != null;

  String get text => sealedText ?? frame.text;
}

/// A peer we connected outward to. We are central, it is peripheral.
class _OutboundLink {
  _OutboundLink({
    required this.peripheral,
    required this.tx,
    required this.rx,
    required this.maxWrite,
  });
  final Peripheral peripheral;
  final GATTCharacteristic tx;
  final GATTCharacteristic rx;
  int maxWrite;
  final DateTime connectedAt = DateTime.now();
}

/// One device, both GATT roles at once -- the bitchat topology.
///
/// Which role actually carries a given peer is decided by a tie-break on the
/// advertised node id, so exactly one side dials. Both stacks stay live either
/// way, and messages flow in both directions regardless of who dialled:
/// central->peripheral by writing RX, peripheral->central by notifying TX.
class MeshLink {
  MeshLink({required this.identity, IdentitySource? source}) {
    _sessions = SessionManager(
      peerId: identity.peerId,
      staticKeyPair: identity.noiseKeyPair,
      onStep: _emitHandshakeStep,
      onEstablished: (peer, role) {
        _log(
          LogLevel.info,
          'session with ${labelOf(peer)} established ($role)',
        );
        unawaited(_shareNostrAddress(peer));
        unawaited(_flushOutbox(peer));
      },
      onFailed: (peer, why) => _log(
        LogLevel.warn,
        'session with ${labelOf(peer)} failed: ${why.name}',
      ),
    );
    _wirePeripheral();
    _wireCentral();
    _announceIdentity(source);
  }

  /// Noise sessions, one per peer.
  ///
  /// Keyed on peer id rather than on a link, because legs churn constantly and
  /// a session tied to one dies with it.
  late final SessionManager _sessions;

  /// Messages waiting for a session, kept as plaintext so they can be sealed
  /// against whatever session exists when the peer finally turns up.
  final Outbox _outbox = Outbox();

  /// Nostr public keys, by mesh peer id, as told to us inside a session.
  ///
  /// Never from an announce or any other unauthenticated source. A peer's
  /// internet address is exactly the thing worth lying about: claim someone
  /// else's npub and their messages come to you instead.
  final Map<String, String> _nostrAddresses = {};

  /// Tells the mesh we exist, so peers that are not neighbours can find us.
  Timer? _announceTimer;

  /// Peers we have heard announce themselves, whether or not we have a leg to
  /// them. This is how a node beyond the first hop becomes addressable at all.
  final Set<String> _announced = {};

  /// Sweeps handshakes that stalled. Nothing acknowledges a handshake step, so
  /// a lost one would otherwise leave a pair unable to ever try again.
  Timer? _sessionSweep;

  /// Who this node is. Derived from a seed that outlives the process, so the
  /// id below is the same on every launch.
  final NodeIdentity identity;

  /// The short label that goes on the air and into logs. Four characters of
  /// the fingerprint, not a random string, so it identifies rather than just
  /// distinguishes.
  String get nodeId => identity.shortId;
  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();

  final _serviceUuid = UUID.fromString(kServiceUuidString);
  final _txUuid = UUID.fromString(kTxCharacteristicUuidString);
  final _rxUuid = UUID.fromString(kRxCharacteristicUuidString);

  // Only TX is kept: notifying needs the characteristic object, whereas
  // inbound writes are identified by UUID off the event.
  GATTCharacteristic? _myTx;

  // Peripheral role: centrals connected to us, and which have subscribed.
  final Map<String, Central> _centrals = {};
  final Map<String, int> _notifyLimit = {};

  /// Peer node ids learned from the in-band hello, keyed by transport key.
  /// Kept separately per direction because the same physical device has two
  /// unrelated identifiers: a Peripheral uuid when we dial it, and a Central
  /// uuid when it dials us. The hello is the only thing that ties them together.
  final Map<String, String> _outPeerId = {};
  final Map<String, String> _inPeerId = {};

  // Central role: peers we dialled.
  final Map<String, _OutboundLink> _links = {};
  final Set<String> _dialling = {};

  /// Peer node ids whose link we deliberately gave up in
  /// [_resolveDuplicateLink], and the transport keys they were reached on.
  /// Without this the drop immediately re-arms discovery and the pair spins:
  /// dial -> hello -> drop -> rediscover -> dial.
  final Set<String> _yieldedTo = {};

  /// Transport keys we hung up on ourselves. Needed separately from
  /// [_yieldedTo] because the disconnect callback arrives *after*
  /// _resolveDuplicateLink has already cleared _outPeerId, so the node id is no
  /// longer available to attribute the disconnect by.
  final Set<String> _yieldedKeys = {};

  /// Legs we have already sent our hello on. Guards the reply below against
  /// ping-ponging: A announces, B replies, A sees it has already announced and
  /// stops.
  final Set<String> _helloSent = {};

  /// Live prune timers, keyed by transport key. Tracked so a re-subscribe can
  /// restart the clock and a hello can cancel it outright -- an untracked timer
  /// from a previous connection cycle will happily fire during the next one and
  /// prune a perfectly healthy peer.
  final Map<String, Timer> _pruneTimers = {};

  /// Node ids we are pretending not to hear, so an A-B-C line topology can be
  /// created on one desk. A blocked peer is dropped in *both* directions --
  /// nothing is sent to it and nothing is accepted from it -- because a
  /// half-blocked peer is not a partition, it is a confusing bug.
  final Set<String> _blocked = {};

  /// Everything the radio can currently see, whether or not we linked to it.
  /// This is the instrument for "is C actually out of range?" -- absence here
  /// is the evidence, and it is independent of whether a link happened to form.
  final Map<String, ObservedPeer> _observed = {};

  /// Exponential backoff per transport key. A link that dies seconds after it
  /// forms will die again if we redial immediately, and discovery re-arms us
  /// within milliseconds -- which turns one bad pairing into a tight loop that
  /// saturates the radio. Observed between Android and iOS, where the two legs
  /// to one peer are not as independent as the model assumes.
  final Map<String, DateTime> _backoffUntil = {};
  final Map<String, int> _flaps = {};

  /// Transport keys with a live GATT connection. `_setUpOutbound` runs a long
  /// await chain (mtu -> discover -> subscribe -> limits -> hello) and the
  /// connection can die at any point in it; without this each remaining step
  /// throws a different platform exception and one dead link looks like four
  /// unrelated bugs.
  final Set<String> _connected = {};

  /// Relays waiting out their random assessment delay, keyed by msgId.
  final Map<String, _PendingRelay> _pendingRelays = {};

  /// One write at a time per link.
  ///
  /// Android allows a single outstanding GATT operation per connection, so a
  /// second write issued before the first completes throws. Relays fire from
  /// independent timers and a fragmented message is a burst of them, so
  /// without this the pieces collide with each other and are lost.
  final Map<String, Future<void>> _linkWrites = {};

  /// Outbound keys we closed ourselves because a newer leg to the same node id
  /// replaced them. Kept apart from [_yieldedKeys] because the two want
  /// opposite things from the disconnect callback: a yielded leg stays in
  /// [_dialling] so discovery leaves the peer alone, while a retired one is a
  /// dead address that should be forgotten completely.
  final Set<String> _retiredKeys = {};

  /// Puts fragmented messages back together. Lives in its own class with its
  /// own tests, because the interesting part is the limits rather than the
  /// gluing, and limits are much easier to test without a radio involved.
  final FragmentAssembler _assembler = FragmentAssembler();

  /// Gap between fragments of one message. Without it we hand the whole set to
  /// the ATT queue at once and the radio has no room for anything else.
  static const _fragmentSpacing = Duration(milliseconds: 20);
  final Random _rnd = Random();
  int _relayed = 0;
  int _suppressed = 0;

  /// Random assessment delay before relaying. Every node that received the same
  /// frame waits a different amount of time, so they do not all rebroadcast at
  /// once and each gets a chance to notice that someone else already did.
  ///
  /// The window has to be large relative to how long a relay takes to *arrive*,
  /// not just how long we wait. Measured on real hardware at 40-200ms, a
  /// three-node desk test relayed 6 of 7 frames and suppressed 1: a BLE write
  /// round trip is itself 30-100ms, so a peer's relay usually landed after our
  /// timer had already fired and the evidence arrived too late to act on.
  /// 150-600ms leaves room to actually hear it. The cost is latency per hop --
  /// with ttl 3 that is two hops, so under ~1.2s worst case, which a messaging
  /// app can afford and a broadcast storm cannot.
  static const _radMinMs = 150;
  static const _radSpreadMs = 450;

  /// Hearing the same frame from one other node during the delay is enough to
  /// conclude our neighbourhood is already covered.
  static const _suppressAfterHeard = 1;
  static const _flapWindow = Duration(seconds: 6);
  static const _backoffCap = Duration(seconds: 30);

  // Bounded dedup. Insertion-ordered so eviction is FIFO.
  final Set<String> _seen = {};
  static const _seenCap = 512;

  final _logs = StreamController<LogLine>.broadcast();

  /// Log lines emitted before anyone subscribed. The constructor logs platform
  /// capability gaps, and a broadcast controller drops events with no listener,
  /// so without this the most diagnostic lines in the whole app are invisible.
  final List<LogLine> _history = [];
  final _messages = StreamController<InboundMessage>.broadcast();
  final List<StreamSubscription> _subs = [];

  bool _running = false;

  Stream<LogLine> get logs => _logs.stream;
  Stream<InboundMessage> get messages => _messages.stream;
  bool get running => _running;
  BluetoothLowEnergyState get state => _central.state;

  /// How many messages are waiting for a session, across all peers.
  int get heldMessages => _outbox.messageCount;

  /// How many are waiting for one peer.
  int heldFor(String peer) => _outbox.pendingFor(peer);

  /// Peers we hold a live Noise session with, so can send a sealed message to.
  List<String> get sessionPeers => _sessions.establishedPeers.toList()..sort();

  /// Everyone we could address, whether or not a session exists yet.
  ///
  /// A peer without a session is still worth offering: the message waits and
  /// goes out when the handshake finishes. That is a different promise from
  /// "this is private right now", so the UI has to show the two apart, but it
  /// is not a false one.
  List<String> get addressablePeers {
    final all = <String>{...sessionPeers, ...knownPeers}
      ..remove(identity.peerId)
      ..removeWhere(_isBlockedId);
    return all.toList()..sort();
  }

  int get outboundPeers => _links.length;
  int get inboundPeers => _centrals.length;
  int get subscribedCentrals => _notifyLimit.length;

  /// Distinct peers, by node id. Counting transport legs double-counts on
  /// Android, where a Central and a Peripheral for the same device both derive
  /// their uuid from the same MAC and are therefore the same key.
  Set<String> get knownPeers =>
      {..._outPeerId.values, ..._inPeerId.values, ..._announced};

  List<String> get peerLabels => [
        ..._links.keys.map(
          (k) => 'out '
              '${_outPeerId[k] == null ? _short(k) : labelOf(_outPeerId[k]!)}',
        ),
        ..._centrals.keys.map(
          (k) => 'in '
              '${_inPeerId[k] == null ? _short(k) : labelOf(_inPeerId[k]!)}'
              '${_notifyLimit.containsKey(k) ? '*' : ''}',
        ),
      ];

  /// Best-known human label for a transport key, either direction.
  String _label(String key) {
    final id = _outPeerId[key] ?? _inPeerId[key];
    return id == null ? _short(key) : labelOf(id);
  }

  /// The four character name for a peer id.
  ///
  /// A hello carries the id, and the label falls out of its first 20 bits, so
  /// there is never a second name to send or to disagree about.
  static String labelOf(String peerId) =>
      peerId.length == 16 ? NodeIdentity.shortLabelForHex(peerId) : peerId;

  Set<String> get blocked => Set.unmodifiable(_blocked);

  int get relayedCount => _relayed;
  int get suppressedCount => _suppressed;

  /// How long a sighting stays listed. Entries must expire, or the row shows
  /// peers that were in range earlier -- which destroys the one measurement the
  /// row exists for: "C never appeared, so C is out of range."
  static const observedTtl = Duration(seconds: 30);

  /// Radio-visible peers seen within [observedTtl], strongest first.
  List<ObservedPeer> get observed {
    _observed.removeWhere((_, o) => o.age > observedTtl);
    final list = _observed.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  /// Puts the identity in the log pane, which is the only place it can be read
  /// on a phone that is not plugged into anything.
  void _announceIdentity(IdentitySource? source) {
    switch (source) {
      case IdentitySource.created:
        _log(LogLevel.info, 'new identity $nodeId created');
      case IdentitySource.restored:
        _log(LogLevel.info, 'identity $nodeId restored');
      case IdentitySource.replaced:
        // Worth shouting about: to every other node on the mesh this device
        // just turned into a stranger.
        _log(
          LogLevel.warn,
          'stored seed was unreadable -- this is a NEW identity, $nodeId',
        );
      case null:
        break;
    }
    _log(LogLevel.info, 'peer id ${identity.peerId}');
    _log(LogLevel.info, 'fingerprint ${identity.readableFingerprint}');
  }

  void block(String nodeId) {
    if (!_blocked.add(nodeId)) return;
    _log(LogLevel.warn, 'blocking $nodeId -- simulating out of range');
    _dropPeer(nodeId);
  }

  void unblock(String nodeId) {
    if (!_blocked.remove(nodeId)) return;
    _log(LogLevel.info, 'unblocked $nodeId');
    _unsuppress(nodeId);
  }

  /// Tears down every leg to [nodeId] in both directions.
  void _dropPeer(String nodeId) {
    bool matches(String id) => id == nodeId || labelOf(id) == nodeId;
    for (final key in _outPeerId.entries
        .where((e) => matches(e.value))
        .map((e) => e.key)
        .toList()) {
      final link = _links.remove(key);
      _outPeerId.remove(key);
      _helloSent.remove(key);
      _yieldedKeys.add(key); // keep discovery from redialling it
      if (link == null) continue;
      _central.disconnect(link.peripheral).catchError((Object e) {
        _log(LogLevel.warn, 'disconnect blocked peer: $e');
      });
    }
    for (final key in _inPeerId.entries
        .where((e) => matches(e.value))
        .map((e) => e.key)
        .toList()) {
      _cancelPrune(key);
      _centrals.remove(key);
      _notifyLimit.remove(key);
      _inPeerId.remove(key);
      _helloSent.remove(key);
    }
  }

  bool _isBlockedKey(String key) {
    final id = _outPeerId[key] ?? _inPeerId[key];
    return id != null && _isBlockedId(id);
  }

  /// Blocks match a peer id or the label derived from it.
  ///
  /// The checkbox list works in ids, which are exact, while the text field is
  /// for typing a label before ever meeting the peer. Both have to land in the
  /// same set for either to be useful.
  bool _isBlockedId(String peerId) =>
      _blocked.contains(peerId) || _blocked.contains(labelOf(peerId));

  List<LogLine> get history => List.unmodifiable(_history);

  void _log(LogLevel level, String text) {
    // Mirror to the platform log as well as the in-app pane. Reading a long
    // stack trace by scrolling a 480x640 screen is not a debugging strategy;
    // `adb logcat -s flutter` is.
    debugPrint('[mesh:${level.name}] $text');
    final line = LogLine(level, text);
    _history.add(line);
    if (_history.length > 400) _history.removeAt(0);
    if (!_logs.isClosed) _logs.add(line);
  }

  /// Android derives a peer's uuid from its MAC and zero-pads the *front*, so
  /// the first 8 chars are all zeros and useless as a label. Take the tail.
  /// First line of an exception, clipped. A Java stack trace in a 480x640 log
  /// pane is noise, and the useful part is always the first line.
  static String _brief(Object e) {
    final first = e.toString().split('\n').first;
    return first.length <= 110 ? first : '${first.substring(0, 110)}...';
  }

  static String _short(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(uuid.length - 8);

  bool _markSeen(String msgId) {
    if (_seen.contains(msgId)) return false;
    _seen.add(msgId);
    if (_seen.length > _seenCap) _seen.remove(_seen.first);
    return true;
  }

  // ---------------------------------------------------------------- lifecycle

  /// User intent, as distinct from [_running]. If the adapter is off when Start
  /// is pressed, we hold this and bring the stack up by ourselves the moment it
  /// powers on.
  bool _wantRunning = false;

  bool get wantRunning => _wantRunning;

  Future<void> start() async {
    if (_running) return;
    _wantRunning = true;

    await _authorize();

    // authorize() returning true means the *permission* was granted. The
    // adapter state arrives separately and asynchronously, so the cached value
    // is still stale at this point. Starting the GATT server against an adapter
    // that is not powered on throws a bare IllegalStateException from the
    // Android platform channel, which tells the user nothing.
    if (!await _waitForPoweredOn(const Duration(seconds: 6))) {
      _log(
        LogLevel.warn,
        'adapter is ${_central.state.name} -- turn Bluetooth on. '
        'Will start by itself once it powers on.',
      );
      return;
    }

    await _startStack();
  }

  Future<bool> _waitForPoweredOn(Duration timeout) async {
    if (_central.state == BluetoothLowEnergyState.poweredOn) return true;
    try {
      await _central.stateChanged
          .firstWhere((e) => e.state == BluetoothLowEnergyState.poweredOn)
          .timeout(timeout);
      return true;
    } catch (_) {
      return _central.state == BluetoothLowEnergyState.poweredOn;
    }
  }

  bool _starting = false;

  Future<void> _startStack() async {
    // `_running` alone is not enough: it is only set at the very end, so two
    // callers (start() and the poweredOn auto-resume) can both get past it
    // during the awaits below and race. The second one used to fail with
    // SCAN_FAILED_ALREADY_STARTED and leave _running false while the stack was
    // in fact up -- which the UI then reported as "Bluetooth is off".
    if (_running || _starting) return;
    _starting = true;
    try {
      await _bringUp();
    } finally {
      _starting = false;
    }
  }

  Future<void> _bringUp() async {
    // Peripheral role is treated as optional on purpose. Some Android devices
    // genuinely cannot advertise, and reporting that plainly is more useful
    // than failing the whole spike -- central-only still proves half the path.
    final peripheralState = _peripheral.state;
    if (peripheralState == BluetoothLowEnergyState.poweredOn) {
      try {
        await _peripheral.removeAllServices();
        final tx = GATTCharacteristic.mutable(
          uuid: _txUuid,
          properties: [GATTCharacteristicProperty.notify],
          permissions: [GATTCharacteristicPermission.read],
          descriptors: [],
        );
        final rx = GATTCharacteristic.mutable(
          uuid: _rxUuid,
          properties: [
            GATTCharacteristicProperty.write,
            GATTCharacteristicProperty.writeWithoutResponse,
          ],
          permissions: [GATTCharacteristicPermission.write],
          descriptors: [],
        );
        _myTx = tx;
        await _peripheral.addService(
          GATTService(
            uuid: _serviceUuid,
            isPrimary: true,
            includedServices: [],
            characteristics: [tx, rx],
          ),
        );
        // No name on Android. The plugin implements Advertisement.name there
        // by calling BluetoothAdapter.setName(), which renames the *phone's*
        // Bluetooth adapter system-wide and never restores it -- every car
        // stereo and headset the user owns would start seeing "BM-XXXX". On
        // iOS it sets CBAdvertisementDataLocalNameKey, a real
        // per-advertisement field with no side effect, so it is safe there.
        //
        // Losing the name on Android costs nothing: identity is exchanged
        // in-band via Frame.hello precisely so it need not ride the
        // advertisement.
        final advertisedName =
            Platform.isAndroid ? null : '$kNamePrefix$nodeId';
        final advertisement =
            Advertisement(name: advertisedName, serviceUUIDs: [_serviceUuid]);
        try {
          await _peripheral.startAdvertising(advertisement);
        } catch (e) {
          // Android error code 3 is ADVERTISE_FAILED_ALREADY_STARTED, and it
          // usually means a previous process of this app is still advertising.
          // A process that is killed rather than stopped, by a cancelled
          // install or by the system, never runs its teardown, and the
          // advertiser it registered outlives it. The new process then starts
          // up believing it is stopped, which it is, while the phone is still
          // broadcasting on its behalf.
          //
          // Stop that one and try again. The same reasoning as the scan path
          // below, which already treats an already-running scan as ours.
          if (!e.toString().contains('error code: 3')) rethrow;
          _log(
            LogLevel.warn,
            'advertising was already running -- stopping it and retrying',
          );
          await _peripheral.stopAdvertising();
          await _peripheral.startAdvertising(advertisement);
        }
        _log(
          LogLevel.info,
          advertisedName == null
              ? 'advertising (unnamed -- android, see comment)'
              : 'advertising as $advertisedName',
        );
      } catch (e) {
        _myTx = null;
        _log(
          LogLevel.error,
          'peripheral role failed ($e) -- continuing central-only, '
          'this device can be found by nobody',
        );
      }
    } else {
      _myTx = null;
      _log(
        LogLevel.warn,
        'peripheral role unavailable (state ${peripheralState.name}) '
        '-- central-only; this device cannot be discovered',
      );
    }

    // Central role. Always filtered by service UUID -- required on iOS to find
    // a backgrounded peer at all.
    // stopDiscovery first so a scan left running by a previous attempt (or by
    // a hot restart) does not make this fail.
    try {
      await _central.stopDiscovery();
    } catch (_) {
      // Nothing was scanning. Fine.
    }
    try {
      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
      _log(
        LogLevel.info,
        'scanning for service ${'$_serviceUuid'.substring(0, 8)}',
      );
      _running = true;
      _startSessionSweep();
      _startAnnouncing();
    } catch (e) {
      // Android error code 1 is SCAN_FAILED_ALREADY_STARTED: the scan we want
      // is running, so this is success wearing an exception.
      if (e.toString().contains('error code: 1')) {
        _log(LogLevel.warn, 'scan was already running -- treating as started');
        _running = true;
        // Same as the success path. Skipping these left a node that resumed
        // this way scanning happily and never announcing or sweeping again.
        _startSessionSweep();
        _startAnnouncing();
      } else {
        _log(LogLevel.error, 'startDiscovery failed: ${_brief(e)}');
      }
    }
  }

  Future<void> stop() async {
    _wantRunning = false;
    // No early return on !_running. Anything that clears _running without
    // tearing down, such as the adapter dropping, used to leave this method
    // with nothing to do while timers kept firing and the radio kept
    // advertising, and the only way out was to kill the app. Teardown is
    // idempotent, so doing it twice is cheaper than skipping it once.
    _running = false;
    await _teardown(releaseRadio: true);
    _log(LogLevel.info, 'stopped');
  }

  /// Puts everything back to a stopped state.
  ///
  /// [releaseRadio] is false when the adapter itself has gone: there is nothing
  /// to disconnect from and nothing to stop advertising, and asking would only
  /// produce errors about a radio that is already off.
  Future<void> _teardown({required bool releaseRadio}) async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _sessionSweep?.cancel();
    _sessionSweep = null;
    for (final t in _pruneTimers.values) {
      t.cancel();
    }
    _pruneTimers.clear();
    for (final r in _pendingRelays.values) {
      r.timer?.cancel();
    }
    _pendingRelays.clear();

    if (releaseRadio) {
      for (final link in _links.values) {
        try {
          await _central.disconnect(link.peripheral);
        } catch (_) {}
      }
    }

    _links.clear();
    _dialling.clear();
    _centrals.clear();
    _notifyLimit.clear();
    _outPeerId.clear();
    _inPeerId.clear();
    _yieldedTo.clear();
    _yieldedKeys.clear();
    _helloSent.clear();
    _backoffUntil.clear();
    _flaps.clear();
    _observed.clear();
    _linkWrites.clear();
    _retiredKeys.clear();
    _announced.clear();
    _outbox.clear();
    _nostrAddresses.clear();
    _assembler.clear();
    _connected.clear();

    if (!releaseRadio) return;

    try {
      await _central.stopDiscovery();
    } catch (e) {
      _log(LogLevel.warn, 'stopDiscovery: $e');
    }
    try {
      await _peripheral.stopAdvertising();
      await _peripheral.removeAllServices();
    } catch (e) {
      _log(LogLevel.warn, 'stopAdvertising: $e');
    }
  }

  Future<void> _authorize() async {
    for (final m in [_central, _peripheral]) {
      if (m.state == BluetoothLowEnergyState.unauthorized &&
          Platform.isAndroid) {
        final granted = await m.authorize();
        _log(
          granted ? LogLevel.info : LogLevel.warn,
          'authorize -> $granted',
        );
      }
    }
  }

  // -------------------------------------------------------------------- send

  /// Broadcasts to every connected peer, in whichever direction that peer sits.
  /// Sends to every distinct peer exactly once.
  ///
  /// Iterating legs would double-send to any peer we hold two legs to, so this
  /// iterates *peers* and picks one leg each -- outbound by preference, since a
  /// write is acknowledged and a notify is not.
  Future<void> send(String text) => _flood(Frame.text(text), 'send');

  /// Seals [text] for [peer] and floods it.
  ///
  /// The mesh carries it like any other frame and every relay forwards bytes it
  /// cannot read. Only [peer] can open it.
  Future<void> sendSealed(String peer, String text) async {
    if (!_sessions.hasSession(peer)) {
      // Held rather than dropped. Typing to a peer before the handshake
      // finishes used to lose the message entirely, with nothing but a warning
      // in a log pane nobody reads.
      _outbox.add(peer, text);
      _log(
        LogLevel.info,
        'no session with ${labelOf(peer)} yet -- '
        '${_outbox.pendingFor(peer)} waiting',
      );
      await _sessions.ensure(peer);
      return;
    }
    final sealed = await _sessions.seal(peer, SealedPayload.encodeText(text));
    if (sealed == null) return;
    await _flood(
      Frame.sealed(
        dest: peer,
        src: identity.peerId,
        counter: sealed.counter,
        ciphertext: sealed.ciphertext,
      ),
      'sealed to ${labelOf(peer)}',
    );
  }

  /// Tells a peer where to reach us when the radio cannot.
  ///
  /// Sent through the session rather than announced, because an unauthenticated
  /// claim about an address is worth nothing: anyone could publish ours and
  /// collect messages meant for us. Inside the session only we could have sent
  /// it.
  Future<void> _shareNostrAddress(String peer) async {
    final address = nostrPublicKey;
    if (address == null) return;
    final sealed = await _sessions.seal(
      peer,
      SealedPayload.encodeNostrAddress(address),
    );
    if (sealed == null) return;
    await _flood(
      Frame.sealed(
        dest: peer,
        src: identity.peerId,
        counter: sealed.counter,
        ciphertext: sealed.ciphertext,
      ),
      'nostr address to ${labelOf(peer)}',
    );
  }

  /// Where a peer can be reached over the internet, if they have told us.
  String? nostrAddressFor(String peer) => _nostrAddresses[peer];

  /// Our own Nostr key, when the app has one. Set by whoever wires the
  /// internet transport; the mesh works perfectly well without it.
  String? nostrPublicKey;

  /// Sends everything that was waiting for this peer.
  ///
  /// Sealed one at a time against the session that exists now, which is the
  /// point: the message that was typed twenty minutes ago goes out under
  /// today's keys rather than the ones it would have used then.
  Future<void> _flushOutbox(String peer) async {
    final waiting = _outbox.take(peer);
    if (waiting.isEmpty) return;
    _log(
      LogLevel.info,
      'sending ${waiting.length} held message(s) to ${labelOf(peer)}',
    );
    for (final text in waiting) {
      await sendSealed(peer, text);
    }
  }

  /// Puts one handshake step on the mesh. Relayable, so it can reach a peer
  /// that is no longer a direct neighbour.
  void _emitHandshakeStep(String dest, int step, Uint8List body) {
    unawaited(
      _flood(
        Frame.handshake(
            dest: dest, src: identity.peerId, step: step, body: body),
        'handshake $step to ${labelOf(dest)}',
      ),
    );
  }

  Future<void> _flood(Frame frame, String what) async {
    final bytes = frame.encode();
    final targets = _sendTargets();
    if (targets.isEmpty) {
      _log(LogLevel.warn, 'no peers to send to');
      return;
    }

    // Sized against the mesh, not against our own links. A piece has to cross
    // hops we cannot see and a relay forwards it untouched, so the only size
    // guaranteed to travel is one every link can carry. Sizing against our own
    // smallest link produced pieces our neighbour accepted and its neighbour
    // could not.
    if (bytes.length <= Frame.meshMtu) {
      _markSeen(frame.msgId);
      _log(
        LogLevel.tx,
        '$what ${frame.shortId} ${bytes.length}B to ${targets.length} peer(s)',
      );
      for (final t in targets) {
        await _sendOn(t, bytes, 'send');
      }
      return;
    }

    await _sendFragmented(frame, bytes, targets);
  }

  /// Splits an oversized frame and sends the pieces.
  ///
  /// The pieces are ordinary frames. Each gets its own msgId so dedup and relay
  /// treat them like any other traffic, and each carries the original ttl so
  /// they travel just as far. Only the destination glues them back together.
  Future<void> _sendFragmented(
    Frame frame,
    Uint8List bytes,
    List<_Target> targets,
  ) async {
    const chunkSize =
        Frame.meshMtu - Frame.headerLength - 2 - Frame.fragmentHeaderLength;

    final parts = Frame.split(bytes, chunkSize: chunkSize, ttl: frame.ttl);
    if (parts == null) {
      _log(
        LogLevel.error,
        'message needs more than ${Frame.maxFragments} pieces -- not sent',
      );
      return;
    }

    // Remember the whole message, not the pieces. If a piece of our own comes
    // back to us we want to drop it, and the reassembled frame carries this id.
    _markSeen(frame.msgId);
    _log(
      LogLevel.tx,
      'send ${frame.shortId} ${bytes.length}B as ${parts.length} pieces '
      'of ${chunkSize}B to ${targets.length} peer(s)',
    );

    for (final part in parts) {
      _markSeen(part.msgId);
      final partBytes = part.encode();
      for (final t in targets) {
        await _sendOn(t, partBytes, 'fragment');
      }
      await Future<void>.delayed(_fragmentSpacing);
    }
  }

  /// One leg per distinct peer. Legs whose peer has not said hello yet are
  /// included on their own: a peer mid-handshake is still worth talking to.
  List<_Target> _sendTargets() {
    final byPeer = <String, _Target>{};
    final anonymous = <_Target>[];

    for (final e in _links.entries) {
      if (_isBlockedKey(e.key)) continue;
      final t = _Target.outbound(e.key, e.value);
      final id = _outPeerId[e.key];
      if (id == null) {
        anonymous.add(t);
      } else {
        byPeer[id] = t; // outbound wins over inbound
      }
    }
    for (final e in _notifyLimit.entries) {
      if (_isBlockedKey(e.key)) continue;
      final central = _centrals[e.key];
      if (central == null) continue;
      final t = _Target.inbound(e.key, central, e.value);
      final id = _inPeerId[e.key];
      if (id == null) {
        anonymous.add(t);
      } else {
        byPeer.putIfAbsent(id, () => t);
      }
    }
    return [...byPeer.values, ...anonymous];
  }

  /// Queues a write behind whatever is already in flight on this link.
  Future<void> _sendOn(_Target t, Uint8List bytes, String what) {
    final prior = _linkWrites[t.key] ?? Future<void>.value();
    // _writeOn swallows its own errors, so one failed write cannot break the
    // chain for every write queued behind it.
    final next = prior.then((_) => _writeOn(t, bytes, what));
    _linkWrites[t.key] = next;
    next.whenComplete(() {
      if (identical(_linkWrites[t.key], next)) _linkWrites.remove(t.key);
    });
    return next;
  }

  Future<void> _writeOn(_Target t, Uint8List bytes, String what) async {
    if (bytes.length > t.maxLength) {
      _log(
        LogLevel.warn,
        '$what ${bytes.length}B exceeds ${t.maxLength}B for '
        '${_label(t.key)} -- needs fragmentation',
      );
      return;
    }
    try {
      final link = t.link;
      if (link != null) {
        await _central.writeCharacteristic(
          link.peripheral,
          link.rx,
          value: bytes,
          type: GATTCharacteristicWriteType.withResponse,
        );
        return;
      }
      final tx = _myTx;
      final central = t.central;
      if (tx == null || central == null) return;
      await _peripheral.notifyCharacteristic(central, tx, value: bytes);
    } catch (e) {
      _log(LogLevel.error, '$what to ${_label(t.key)}: ${_brief(e)}');
    }
  }

  void _handleInbound(Uint8List bytes, String via, String key) {
    // Stopped means off the mesh. The platform listeners stay wired until
    // dispose, so a peer that still holds a GATT connection can keep writing
    // to us long after the user pressed Stop, and without this a stopped node
    // goes on decoding, deduping and relaying other people's traffic.
    if (!_running) return;

    // A blocked peer is treated as unreachable in both directions. Accepting
    // its frames while refusing to send would not be a partition.
    if (_isBlockedKey(key)) return;

    final peer = _label(key);
    final frame = Frame.decode(bytes);
    if (frame == null) {
      _log(LogLevel.warn, 'undecodable ${bytes.length}B from $peer');
      return;
    }

    // Hellos are per-link, not mesh traffic: they are never deduped, never
    // relayed, and never shown as messages.
    if (frame.isHello) {
      final peerId = frame.text;
      _identify(key, peerId, via);
      _cancelPrune(key);
      if (_isBlockedId(peerId)) {
        _log(LogLevel.warn,
            'hello from blocked ${labelOf(peerId)} -- dropping leg');
        _dropPeer(peerId);
        return;
      }
      _log(LogLevel.info, 'hello from ${labelOf(peerId)} via $via');

      // Answer on the same leg. Relying on the peer's subscribe event to
      // trigger their hello leaves a leg unidentified whenever that event
      // races or their notify fails -- and one unidentified leg is enough to
      // stop _resolveDuplicateLink acting, which is how a pair ends up
      // permanently double-linked.
      if (!_helloSent.contains(key)) {
        if (via == 'notify') {
          final link = _links[key];
          if (link != null) unawaited(_sendHelloOutbound(link));
        } else {
          final central = _centrals[key];
          if (central != null) unawaited(_sendHelloInbound(central));
        }
      }

      _retireStaleLegs(peerId, key, via);
      _resolveDuplicateLink(peerId);
      // A hello is the first moment we know who this is, so it is the first
      // moment a session can be started. ensure is idempotent, and helloes
      // repeat on every reconnect, which is also what keeps a neighbour's
      // session from going idle.
      _sessions.noteSeen(peerId);
      unawaited(_sessions.ensure(peerId));
      return;
    }

    if (!_markSeen(frame.msgId)) {
      // A duplicate is not just noise: if we are still holding this frame for
      // relay, someone else has already broadcast it, which is exactly the
      // evidence needed to decide our own relay would be redundant.
      final pending = _pendingRelays[frame.msgId];
      if (pending != null) {
        pending.heardFromOthers++;
        _log(
          LogLevel.info,
          'dup ${frame.shortId} -- heard ${pending.heardFromOthers}x '
          'while queued',
        );
      } else {
        _log(LogLevel.info, 'dup ${frame.shortId} dropped');
      }
      return;
    }
    if (frame.envelopeVer != Frame.envelopeVersion) {
      _log(
        LogLevel.warn,
        'envelope v${frame.envelopeVer} unknown -- frozen fields still parsed, '
        'would relay',
      );
    }
    _log(
      LogLevel.rx,
      'recv ${frame.shortId} ${bytes.length}B via $via from $peer',
    );

    // Forward before rendering, and regardless of whether we can read it.
    _scheduleRelay(bytes, key, frame);

    // A piece of a bigger message. It has already been relayed above, exactly
    // like any other frame, so all that is left is to try to put the message
    // back together.
    if (frame.isFragment) {
      _collect(frame, via, peer);
      return;
    }

    // Somebody saying they exist. Deliberately not cancelled from the relay:
    // unlike an addressed frame this has not "arrived" anywhere, and the whole
    // job is to keep going so the far side of the mesh hears it too.
    if (frame.isAnnounce) {
      final announce = Announce.parse(frame);
      if (announce == null) {
        _log(LogLevel.warn, 'malformed announce from $peer -- dropped');
        return;
      }
      if (announce.peerId == identity.peerId) return;
      if (_announced.add(announce.peerId)) {
        _log(LogLevel.info, 'discovered ${announce.label}');
      }
      // An announce reaches us through relays, so it is evidence about peers a
      // hello can never tell us anything about, both that they exist and that
      // they are still alive.
      _sessions.noteSeen(announce.peerId);
      if (!_isBlockedId(announce.peerId)) {
        unawaited(_sessions.ensure(announce.peerId));
      }
      return;
    }

    // Addressed traffic. Relaying already happened above, exactly as for any
    // other frame, because a relay cannot tell these apart and does not need
    // to. What is left is deciding whether this one is ours.
    if (frame.isHandshake) {
      final step = HandshakeMessage.parse(frame);
      if (step == null) {
        _log(LogLevel.warn, 'malformed handshake from $peer -- dropped');
        return;
      }
      // Somebody else's step. It has already been relayed above.
      if (step.dest != identity.peerId) return;
      _cancelRelay(frame.msgId);
      _log(
        LogLevel.info,
        'handshake ${step.step} from ${step.srcLabel}',
      );
      unawaited(_sessions.handleStep(step.src, step.step, step.body));
      return;
    }

    if (frame.isSealed) {
      final envelope = SealedEnvelope.parse(frame);
      if (envelope == null) {
        _log(LogLevel.warn, 'malformed sealed frame from $peer -- dropped');
        return;
      }
      if (envelope.dest != identity.peerId) return;
      _cancelRelay(frame.msgId);
      unawaited(_openSealed(envelope, frame, via, peer));
      return;
    }

    // Relay-but-do-not-render. A node that cannot interpret a payload must
    // still forward it, but it must not show it to the user -- displaying an
    // opaque blob as if it were a message is how a stale build turns another
    // node's protocol traffic into visible noise.
    if (!frame.isReadableText) {
      _log(
        LogLevel.warn,
        'inner v${frame.innerVer} type ${frame.type} unknown '
        '-- relayable, not rendered',
      );
      return;
    }
    if (!_messages.isClosed) {
      _messages.add(InboundMessage(frame: frame, via: via, peer: peer));
    }
  }

  // ------------------------------------------------------------- reassembly

  /// Takes one piece of a larger message and, once the set is complete, hands
  /// the rebuilt frame back to the normal receive path.
  ///
  /// The rebuilt frame is delivered locally and never relayed. The pieces did
  /// the relaying on their way here, so forwarding the whole thing again would
  /// put the same message on the radio twice.
  void _collect(Frame frame, String via, String peer) {
    final part = FragmentPart.parse(frame);
    if (part == null) {
      _log(LogLevel.warn, 'malformed fragment from $peer -- dropped');
      return;
    }

    final outcome = _assembler.add(part);
    for (final id in _assembler.expiredIds) {
      _log(LogLevel.warn, 'gave up on ${id.substring(0, 6)}, went quiet');
    }

    switch (outcome.status) {
      case AssemblyStatus.started:
        _log(
          LogLevel.info,
          'assembling ${part.shortId}, ${part.total} pieces, from $peer',
        );
      case AssemblyStatus.stored:
        _log(
          LogLevel.info,
          '${part.shortId} ${outcome.have}/${outcome.total}',
        );
      case AssemblyStatus.duplicate:
        return;
      case AssemblyStatus.oversized:
        _log(
          LogLevel.warn,
          '${part.shortId} would exceed the size limit -- abandoned',
        );
        return;
      case AssemblyStatus.complete:
        _deliverRebuilt(outcome.data!, part, via, peer);
    }
  }

  /// A rebuilt message is delivered locally and never relayed. The pieces did
  /// the relaying on their way here, so forwarding the whole thing again would
  /// put the same message on the radio a second time.
  void _deliverRebuilt(
    Uint8List bytes,
    FragmentPart part,
    String via,
    String peer,
  ) {
    final rebuilt = Frame.decode(bytes);
    if (rebuilt == null) {
      _log(LogLevel.warn, '${part.shortId} rebuilt into nothing usable');
      return;
    }
    if (!_markSeen(rebuilt.msgId)) {
      _log(LogLevel.info, '${part.shortId} rebuilt, already seen -- dropped');
      return;
    }

    _log(
      LogLevel.rx,
      'rebuilt ${rebuilt.shortId} from ${part.total} pieces, ${bytes.length}B',
    );

    if (!rebuilt.isReadableText) {
      _log(
        LogLevel.warn,
        'rebuilt inner v${rebuilt.innerVer} type ${rebuilt.type} unknown',
      );
      return;
    }
    if (!_messages.isClosed) {
      _messages.add(InboundMessage(frame: rebuilt, via: via, peer: peer));
    }
  }

  // ------------------------------------------------------------------- relay

  /// Forwards a frame one hop, to every peer except the one it came from.
  ///
  /// Deliberately independent of whether we could read the payload: the whole
  /// reason the envelope is split is so a node can carry traffic it does not
  /// understand. Loop prevention is the dedup cache, which has already accepted
  /// this msgId by the time we get here, so a frame can never come back around.
  /// Queues a relay behind a random assessment delay, then relays only if no
  /// other node beat us to it. This is the counter-based scheme from the
  /// broadcast-storm literature, and it is closed-loop: the decision is made
  /// from what we actually heard, not from a guess about network size.
  ///
  /// The alternative -- relay with probability p derived from an estimated peer
  /// count, which is what bitchat does -- is open-loop. It cannot tell a node
  /// with five redundant neighbours from a bridge node that is the only path,
  /// so at p<1 it will eventually drop a frame that nobody else can carry and
  /// nothing detects the hole. Counting duplicates cannot make that mistake: a
  /// bridge hears no one else, so it always relays.
  /// Gives up on handshakes that stalled, so they can be tried again.
  ///
  /// Nothing acknowledges a handshake step. It floods like any other frame and
  /// can simply be lost, and without this a single lost step would leave a pair
  /// unable to ever form a session.
  /// Announces us now and then keeps announcing.
  ///
  /// Repeating matters as much as the first one: a node that joins later has
  /// no way to ask who is out there, so the mesh has to keep saying.
  void _startAnnouncing() {
    _announceTimer?.cancel();
    unawaited(_announce());
    _announceTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_announce()),
    );
  }

  Future<void> _announce() =>
      _flood(Frame.announce(identity.peerId), 'announce');

  void _startSessionSweep() {
    _sessionSweep?.cancel();
    _sessionSweep = Timer.periodic(const Duration(seconds: 5), (_) {
      final swept = _sessions.sweep();
      for (final peer in swept.stalledHandshakes) {
        _log(LogLevel.warn, 'handshake with ${labelOf(peer)} timed out');
      }
      for (final peer in swept.idleSessions) {
        _log(LogLevel.info, 'session with ${labelOf(peer)} went idle');
      }
      for (final entry in _outbox.expire().entries) {
        _log(
          LogLevel.warn,
          'gave up on ${entry.value} message(s) for ${labelOf(entry.key)}',
        );
      }
    });
  }

  /// Calls off a relay we queued before realising the frame was for us.
  ///
  /// It arrived, so forwarding it again would put a message on the radio that
  /// nobody is waiting for.
  void _cancelRelay(String msgId) {
    _pendingRelays.remove(msgId)?.timer?.cancel();
  }

  /// Opens a sealed message, or says why it could not be opened.
  Future<void> _openSealed(
    SealedEnvelope envelope,
    Frame frame,
    String via,
    String peer,
  ) async {
    try {
      final plain = await _sessions.open(
        envelope.src,
        envelope.counter,
        envelope.ciphertext,
      );
      // A message that opened could only have come from them, and for a peer
      // reached through a relay this is the only evidence there is: a hello
      // never travels that far.
      _sessions.noteSeen(envelope.src);

      final payload = SealedPayload.parse(plain);
      if (payload == null) {
        // Authenticated, so it really is from them, just a kind this build
        // does not know. Same rule as the outer frame: do not render it.
        _log(
          LogLevel.warn,
          'sealed payload from ${envelope.srcLabel} is a kind we do not know',
        );
        return;
      }

      if (payload.kind == SealedKind.nostrAddress) {
        // Their internet address, learned through the one channel where the
        // claim cannot be forged.
        final known = _nostrAddresses[envelope.src];
        _nostrAddresses[envelope.src] = payload.hex;
        if (known != payload.hex) {
          _log(
            LogLevel.info,
            'nostr address for ${envelope.srcLabel}: '
            '${payload.hex.substring(0, 12)}...',
          );
        }
        return;
      }

      final text = payload.text;
      _log(
        LogLevel.rx,
        'sealed message from ${envelope.srcLabel}, '
        '${envelope.ciphertext.length}B',
      );
      if (!_messages.isClosed) {
        _messages.add(
          InboundMessage(
            frame: frame,
            via: via,
            peer: peer,
            sealedFrom: envelope.src,
            sealedText: text,
          ),
        );
      }
    } on NoiseError catch (e) {
      // Expected often enough to be worth saying plainly: a peer that restarted
      // has a session we no longer share, and its messages cannot open.
      _log(
        LogLevel.warn,
        'sealed message from ${envelope.srcLabel} did not open (${e.message})',
      );
      unawaited(_sessions.ensure(envelope.src));
    }
  }

  void _scheduleRelay(Uint8List bytes, String fromKey, Frame frame) {
    final forward = Frame.forwarded(bytes);
    if (forward == null) {
      _log(LogLevel.info, 'ttl exhausted for ${frame.shortId} -- not relayed');
      return;
    }

    final delayMs = _radMinMs + _rnd.nextInt(_radSpreadMs);
    final pending = _PendingRelay(forward: forward, fromKey: fromKey);
    _pendingRelays[frame.msgId] = pending;
    pending.timer = Timer(Duration(milliseconds: delayMs), () {
      _pendingRelays.remove(frame.msgId);
      if (pending.heardFromOthers >= _suppressAfterHeard) {
        _suppressed++;
        _log(
          LogLevel.info,
          'suppressed relay of ${frame.shortId} -- heard it '
          '${pending.heardFromOthers}x from others',
        );
        return;
      }
      _relay(pending.forward, pending.fromKey, frame);
    });
    _log(
      LogLevel.info,
      'relay of ${frame.shortId} queued ${delayMs}ms (assessment delay)',
    );
  }

  void _relay(Uint8List forward, String fromKey, Frame frame) {
    // Exclude the sender by node id, not just transport key: on iOS the two
    // legs to one device carry unrelated identifiers, so keying alone would
    // hand the frame straight back to whoever sent it.
    final fromId = _outPeerId[fromKey] ?? _inPeerId[fromKey];
    final targets = _sendTargets()
        .where(
          (t) =>
              t.key != fromKey &&
              (fromId == null ||
                  (_outPeerId[t.key] != fromId && _inPeerId[t.key] != fromId)),
        )
        .toList();

    if (targets.isEmpty) {
      _log(LogLevel.info, 'nowhere to relay ${frame.shortId}');
      return;
    }
    _relayed++;
    _log(
      LogLevel.tx,
      'relay ${frame.shortId} ttl ${frame.ttl}->${frame.ttl - 1} '
      'to ${targets.length} peer(s)',
    );
    for (final t in targets) {
      _sendOn(t, forward, 'relay');
    }
  }

  // ------------------------------------------------------------ subscriptions

  /// Subscribes to a stream that may not exist on this platform.
  ///
  /// The platform interface declares every stream unconditionally, but the
  /// darwin implementation makes several of them *throw UnsupportedError from
  /// the getter itself*. Touching one during construction takes down the first
  /// frame, which in a release build shows up as a blank grey screen with no
  /// hint as to why. So the getter access happens in here, behind a catch, and
  /// an absent stream degrades to a log line.
  void _safeListen<T>(
    Stream<T> Function() stream,
    void Function(T) onData, {
    required String label,
  }) {
    try {
      _subs.add(stream().listen(onData));
    } on UnsupportedError {
      _log(LogLevel.info, '$label not available on this platform');
    } catch (e) {
      _log(LogLevel.warn, '$label subscribe failed: ${_brief(e)}');
    }
  }

  void _wirePeripheral() {
    _safeListen(
      () => _peripheral.stateChanged,
      (e) => _log(LogLevel.info, 'peripheral adapter ${e.state.name}'),
      label: 'peripheral.stateChanged',
    );

    // Android only. Darwin has no peripheral-side connection events at all, and
    // no way to enumerate connected centrals either, so the registry below is
    // driven by events that actually carry a Central. This is the extra signal,
    // never the source of truth.
    _safeListen(
      () => _peripheral.connectionStateChanged,
      (e) {
        final key = '${e.central.uuid}';
        if (e.state == ConnectionState.connected) {
          _centrals[key] = e.central;
          _log(LogLevel.info, 'central ${_short(key)} connected to us');
          // A central that connects and never subscribes is a leftover. The
          // Android stack hands a new process the GATT connections the old one
          // left open, so the app can start with several of these already in
          // the registry. Arm the same prune the subscribe path uses: without
          // it nothing here is ever reclaimed, and a long session measured 61
          // connects against 47 disconnects and zero prunes.
          _scheduleUnidentifiedPrune(key);
        } else {
          _cancelPrune(key);
          _centrals.remove(key);
          _notifyLimit.remove(key);
          _helloSent.remove(key);
          final goneId = _inPeerId.remove(key);
          _log(LogLevel.info, 'central ${goneId ?? _short(key)} gone');
          if (goneId != null) _unsuppress(goneId);
        }
      },
      label: 'peripheral.connectionStateChanged',
    );

    // Supported everywhere, and the real source of truth for "a central exists
    // and we can notify it".
    _safeListen(
      () => _peripheral.characteristicNotifyStateChanged,
      (e) async {
        if (e.characteristic.uuid != _txUuid) return;
        final key = '${e.central.uuid}';
        if (e.state) {
          _centrals[key] = e.central;
          try {
            final limit = await _peripheral.getMaximumNotifyLength(e.central);
            _notifyLimit[key] = limit;
            _log(
              LogLevel.info,
              'central ${_short(key)} subscribed, notify limit ${limit}B',
            );
            await _sendHelloInbound(e.central);
            _scheduleUnidentifiedPrune(key);
          } catch (err) {
            _notifyLimit[key] = 20;
            _log(LogLevel.warn, 'notify limit unknown ($err), assuming 20B');
          }
        } else {
          _cancelPrune(key);
          _notifyLimit.remove(key);
          _centrals.remove(key);
          _helloSent.remove(key);
          final goneId = _inPeerId.remove(key);
          _log(LogLevel.info, 'central ${goneId ?? _short(key)} unsubscribed');
          if (goneId != null) _unsuppress(goneId);
        }
      },
      label: 'peripheral.characteristicNotifyStateChanged',
    );

    _safeListen(
      () => _peripheral.characteristicWriteRequested,
      (e) async {
        // Respond first. A stalled ATT response blocks the peer's queue and
        // looks exactly like a dead link.
        try {
          await _peripheral.respondWriteRequest(e.request);
        } catch (err) {
          _log(LogLevel.error, 'respondWriteRequest: $err');
        }
        if (e.characteristic.uuid != _rxUuid) return;
        // A central that writes is a central we know about, whether or not we
        // ever saw a connection event for it.
        _centrals.putIfAbsent('${e.central.uuid}', () => e.central);
        _handleInbound(e.request.value, 'write', '${e.central.uuid}');
      },
      label: 'peripheral.characteristicWriteRequested',
    );

    _safeListen(
      () => _peripheral.characteristicReadRequested,
      (e) async {
        try {
          await _peripheral.respondReadRequestWithValue(
            e.request,
            value: Uint8List(0),
          );
        } catch (err) {
          _log(LogLevel.error, 'respondReadRequest: $err');
        }
      },
      label: 'peripheral.characteristicReadRequested',
    );

    // Android only. The numbers that actually matter come from
    // getMaximumNotifyLength / getMaximumWriteLength, which work everywhere.
    _safeListen(
      () => _peripheral.mtuChanged,
      (e) async {
        final key = '${e.central.uuid}';
        _log(LogLevel.info, 'mtu ${e.mtu} with central ${_short(key)}');
        // A central can subscribe before MTU negotiation finishes, and the
        // limit recorded then is the 23 byte ATT default. Re-read it whenever
        // the MTU moves, or that leg stays pinned at 20B for its whole life
        // and refuses everything bigger.
        if (!_notifyLimit.containsKey(key)) return;
        try {
          final limit = await _peripheral.getMaximumNotifyLength(e.central);
          if (_notifyLimit[key] == limit) return;
          _notifyLimit[key] = limit;
          _log(
            LogLevel.info,
            'notify limit for ${_label(key)} now ${limit}B',
          );
        } catch (err) {
          _log(LogLevel.warn, 'notify limit refresh failed: $err');
        }
      },
      label: 'peripheral.mtuChanged',
    );
  }

  // ----------------------------------------------------------- central wiring

  void _wireCentral() {
    _safeListen(
      () => _central.stateChanged,
      (e) {
        _log(LogLevel.info, 'central adapter ${e.state.name}');
        if (e.state == BluetoothLowEnergyState.poweredOn &&
            _wantRunning &&
            !_running) {
          _log(LogLevel.info, 'adapter came up -- starting');
          _startStack();
        } else if (e.state != BluetoothLowEnergyState.poweredOn && _running) {
          // The links are gone with the radio; do not keep claiming to run.
          // Timers have to go with them: leaving them running was how a node
          // ended up announcing every 30 seconds while its own UI said it was
          // stopped.
          _running = false;
          unawaited(_teardown(releaseRadio: false));
          _log(LogLevel.warn, 'adapter ${e.state.name} -- stack torn down');
        }
      },
      label: 'central.stateChanged',
    );

    _safeListen(
      () => _central.discovered,
      _onDiscovered,
      label: 'central.discovered',
    );

    _safeListen(
      () => _central.connectionStateChanged,
      (e) async {
        final key = '${e.peripheral.uuid}';
        if (e.state == ConnectionState.connected) {
          _connected.add(key);
          await _setUpOutbound(e.peripheral);
        } else {
          _connected.remove(key);
          // A leg we retired ourselves. No flap accounting and no redial: this
          // is a rotated address that will not come back, so every trace of it
          // goes. The peer is still here under its current key.
          if (_retiredKeys.remove(key)) {
            _links.remove(key);
            _outPeerId.remove(key);
            _helloSent.remove(key);
            _dialling.remove(key);
            _flaps.remove(key);
            _backoffUntil.remove(key);
            _observed.remove(key);
            _linkWrites.remove(key);
            _log(LogLevel.info, 'stale leg ${_short(key)} closed');
            return;
          }
          final wasYielded = _yieldedKeys.contains(key);
          final lived = _links[key] == null
              ? null
              : DateTime.now().difference(_links[key]!.connectedAt);
          if (!wasYielded && lived != null && lived < _flapWindow) {
            final n = (_flaps[key] ?? 0) + 1;
            _flaps[key] = n;
            final wait = Duration(seconds: 1 << (n > 5 ? 5 : n));
            final capped = wait > _backoffCap ? _backoffCap : wait;
            _backoffUntil[key] = DateTime.now().add(capped);
            _log(
              LogLevel.warn,
              'link to ${_label(key)} lasted ${lived.inMilliseconds}ms '
              '(flap $n) -- backing off ${capped.inSeconds}s',
            );
          } else if (lived != null && lived >= _flapWindow) {
            _flaps.remove(key);
            _backoffUntil.remove(key);
          }
          _helloSent.remove(key);
          _links.remove(key);
          _outPeerId.remove(key);
          if (wasYielded) {
            // Our own dedupe hang-up. Keep the key in _dialling so discovery
            // leaves it alone; the peer's inbound leg carries the traffic.
            _log(LogLevel.info, 'peer ${_short(key)} released (deduped)');
          } else {
            _dialling.remove(key);
            _log(LogLevel.info, 'peer ${_short(key)} disconnected');
          }
        }
      },
      label: 'central.connectionStateChanged',
    );

    _safeListen(
      () => _central.characteristicNotified,
      (e) {
        if (e.characteristic.uuid != _txUuid) return;
        _handleInbound(e.value, 'notify', '${e.peripheral.uuid}');
      },
      label: 'central.characteristicNotified',
    );

    // Android only, same reasoning as above.
    _safeListen(
      () => _central.mtuChanged,
      (e) => _log(
        LogLevel.info,
        'mtu ${e.mtu} with peer ${_short('${e.peripheral.uuid}')}',
      ),
      label: 'central.mtuChanged',
    );
  }

  Future<void> _onDiscovered(DiscoveredEventArgs e) async {
    // Same reasoning as the inbound path: a scan result arriving after Stop
    // must not start a new connection.
    if (!_running) return;

    final key = '${e.peripheral.uuid}';

    String? advertisedName;
    try {
      advertisedName = e.advertisement.name;
    } catch (_) {
      advertisedName = null; // getter throws on unsupported platforms
    }

    // Record every sighting, before any decision about dialling. This is what
    // makes "C never appeared" an observation rather than an inference.
    final seen = _observed[key];
    if (seen == null) {
      _observed[key] = ObservedPeer(
        key: key,
        name: advertisedName,
        rssi: e.rssi,
      );
    } else {
      seen.rssi = e.rssi;
      seen.lastSeen = DateTime.now();
    }

    // A blocked peer stays visible on the radio -- that is the point, it is
    // "out of range" only as far as the protocol is concerned.
    if (advertisedName != null && advertisedName.startsWith(kNamePrefix)) {
      final id = advertisedName.substring(kNamePrefix.length);
      if (_blocked.contains(id)) return;
    }

    if (_links.containsKey(key) || _dialling.contains(key)) return;

    final until = _backoffUntil[key];
    if (until != null && DateTime.now().isBefore(until)) return;

    // No tie-break on the advertised name. Android cannot advertise an
    // arbitrary local name at all -- AdvertiseData only has
    // setIncludeDeviceName(bool) -- so the name is the phone's adapter name
    // there and our prefix never matches. Both sides therefore dial, and the
    // in-band hello tears the redundant link down deterministically. Uniform
    // across platforms beats a tie-break that silently works on one of them.
    final peerName = advertisedName;

    _dialling.add(key);
    _log(
      LogLevel.info,
      'dialling ${peerName ?? _short(key)} (rssi ${e.rssi})',
    );
    try {
      await _central.connect(e.peripheral);
    } catch (err) {
      _dialling.remove(key);
      _log(LogLevel.error, 'connect ${_short(key)}: ${_brief(err)}');
    }
  }

  // ------------------------------------------------------------------- hello

  Future<void> _sendHelloOutbound(_OutboundLink link) async {
    _helloSent.add('${link.peripheral.uuid}');
    try {
      await _central.writeCharacteristic(
        link.peripheral,
        link.rx,
        value: Frame.hello(identity.peerId).encode(),
        type: GATTCharacteristicWriteType.withResponse,
      );
    } catch (e) {
      _log(LogLevel.warn, 'hello write failed: ${_brief(e)}');
    }
  }

  Future<void> _sendHelloInbound(Central central) async {
    final tx = _myTx;
    if (tx == null) return;
    _helloSent.add('${central.uuid}');
    try {
      await _peripheral.notifyCharacteristic(
        central,
        tx,
        value: Frame.hello(identity.peerId).encode(),
      );
    } catch (e) {
      _log(LogLevel.warn, 'hello notify failed: ${_brief(e)}');
    }
  }

  /// The inbound leg we kept has gone away, so this peer is no longer reachable
  /// at all. Lift the dial suppression that _resolveDuplicateLink put in place,
  /// or we would never reconnect to it.
  void _unsuppress(String peerId) {
    if (!_yieldedTo.remove(peerId)) return;
    _yieldedKeys.removeWhere((k) {
      _dialling.remove(k);
      return true;
    });
    _log(LogLevel.info, '${labelOf(peerId)} gone -- dialling re-armed');
  }

  /// Retires legs to [peerId] other than [keepKey], in the same direction.
  ///
  /// Android rotates the address it advertises, so one phone reappears under a
  /// stream of transport keys and each one adds a leg. Nothing removed the old
  /// ones: a long session ended up holding fourteen central keys for two real
  /// phones. A hello is the first moment we can tell that two keys are the same
  /// peer, so that is where the older leg goes.
  ///
  /// Inbound legs are only forgotten, never hung up. They belong to the peer,
  /// and if one really is still alive its next write registers it again. An
  /// outbound leg is our own GATT connection, so forgetting it without
  /// disconnecting would leak it, and Android allows only a handful at once.
  void _retireStaleLegs(String peerId, String keepKey, String via) {
    if (via == 'notify') {
      for (final key in _outPeerId.entries
          .where((e) => e.value == peerId && e.key != keepKey)
          .map((e) => e.key)
          .toList()) {
        final link = _links[key];
        if (link == null) {
          _outPeerId.remove(key);
          continue;
        }
        _retiredKeys.add(key);
        _log(LogLevel.info,
            'retiring stale leg to ${labelOf(peerId)} (${_short(key)})');
        _central.disconnect(link.peripheral).catchError((Object e) {
          // The address is already gone often enough that this is expected.
          _retiredKeys.remove(key);
          _links.remove(key);
          _outPeerId.remove(key);
          _log(LogLevel.info, 'stale leg ${_short(key)} was already gone');
        });
      }
      return;
    }
    for (final key in _inPeerId.entries
        .where((e) => e.value == peerId && e.key != keepKey)
        .map((e) => e.key)
        .toList()) {
      _cancelPrune(key);
      _centrals.remove(key);
      _notifyLimit.remove(key);
      _inPeerId.remove(key);
      _helloSent.remove(key);
      _linkWrites.remove(key);
      _log(LogLevel.info,
          'forgetting stale leg from ${labelOf(peerId)} (${_short(key)})');
    }
  }

  /// A central that subscribes but never sends a hello is a leftover: either a
  /// half-dead connection or a peer that went away mid-handshake. Drop it so
  /// the peer count means something.
  void _scheduleUnidentifiedPrune(String key) {
    _pruneTimers.remove(key)?.cancel();
    _pruneTimers[key] = Timer(const Duration(seconds: 8), () {
      _pruneTimers.remove(key);
      if (!_centrals.containsKey(key)) return;
      if (_inPeerId.containsKey(key)) return; // identified itself, keep it
      _centrals.remove(key);
      _notifyLimit.remove(key);
      _log(LogLevel.warn, 'central ${_short(key)} never said hello -- pruned');
    });
  }

  /// Records who a leg belongs to, and the other leg under the same key.
  ///
  /// On Android both GATT roles for one device derive their key from the same
  /// MAC, so a hello arriving on either leg has identified both. Only one was
  /// being recorded, which left the other unidentified for good, because a
  /// hello arrives once per link and the second one never comes.
  ///
  /// That is worse than an untidy peer list. _sendTargets treats an
  /// unidentified but subscribed inbound leg as its own anonymous peer, so it
  /// escapes the per-peer dedupe and gets a second copy of every message,
  /// delivered to a device that already received it on the other leg.
  ///
  /// The guard is what keeps this correct on darwin, where the two legs to one
  /// device carry unrelated identifiers: the other role is simply never present
  /// under the same key there, so nothing extra is recorded.
  void _identify(String key, String peerId, String via) {
    if (via == 'notify') {
      _outPeerId[key] = peerId;
      if (_centrals.containsKey(key)) _inPeerId[key] = peerId;
    } else {
      _inPeerId[key] = peerId;
      if (_links.containsKey(key)) _outPeerId[key] = peerId;
    }
  }

  void _cancelPrune(String key) => _pruneTimers.remove(key)?.cancel();

  /// Notes that a peer is reachable on more than one leg. Deliberately does
  /// *not* disconnect anything.
  ///
  /// Tearing a leg down looked right and was wrong: on Android both GATT roles
  /// for one remote report under a single MAC-derived key, so hanging up "our
  /// outbound" is indistinguishable from the peer hanging up its inbound, and
  /// the platform took the surviving leg with it. Against iOS that produced an
  /// endless dial / hello / drop / redial loop.
  ///
  /// Redundant legs cost a connection slot, but duplicate *delivery* is already
  /// handled: sending picks one leg per peer and the dedup cache catches
  /// anything that still arrives twice. Cheap, and it does not fight the
  /// platform over who owns a connection.
  void _resolveDuplicateLink(String peerId) {
    var legs = 0;
    for (final v in _outPeerId.values) {
      if (v == peerId) legs++;
    }
    for (final v in _inPeerId.values) {
      if (v == peerId) legs++;
    }
    if (legs > 1) {
      _log(
        LogLevel.info,
        '${labelOf(peerId)} reachable on $legs legs -- sending on one',
      );
    }
  }

  GATTService? _findMeshService(List<GATTService> services) {
    for (final s in services) {
      if (s.uuid == _serviceUuid) return s;
    }
    return null;
  }

  Future<void> _setUpOutbound(Peripheral peripheral) async {
    final key = '${peripheral.uuid}';
    try {
      if (Platform.isAndroid) {
        try {
          final mtu = await _central.requestMTU(peripheral, mtu: 517);
          _log(LogLevel.info, 'negotiated mtu $mtu');
        } catch (err) {
          _log(LogLevel.warn, 'requestMTU: ${_brief(err)}');
        }
      }

      if (!_connected.contains(key)) return;

      // A freshly connected Android peer sometimes reports zero services, then
      // reports them correctly a moment later. One retry turns that from a lost
      // link into a slower one.
      var services = await _central.discoverGATT(peripheral);
      var service = _findMeshService(services);
      if (service == null) {
        _log(
          LogLevel.warn,
          'no mesh service in ${services.length} services -- retrying discovery',
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
        services = await _central.discoverGATT(peripheral);
        service = _findMeshService(services);
      }
      if (!_connected.contains(key)) {
        _log(LogLevel.info, 'peer ${_short(key)} vanished during discovery');
        _dialling.remove(key);
        return;
      }
      if (service == null) {
        _log(
          LogLevel.error,
          'peer ${_short(key)} has no mesh service '
          '(found ${services.length} services) -- disconnecting',
        );
        // Re-arm discovery: this peer may simply have been mid-setup, and
        // leaving the key in _dialling would blacklist it for the whole run.
        _dialling.remove(key);
        await _central.disconnect(peripheral);
        return;
      }

      GATTCharacteristic? tx;
      GATTCharacteristic? rx;
      for (final c in service.characteristics) {
        if (c.uuid == _txUuid) tx = c;
        if (c.uuid == _rxUuid) rx = c;
      }
      if (tx == null || rx == null) {
        _log(
            LogLevel.error, 'peer ${_short(key)} missing tx/rx characteristic');
        _dialling.remove(key);
        await _central.disconnect(peripheral);
        return;
      }

      // Register BEFORE subscribing. Subscribing is what makes the peer notify
      // its hello, and that hello can arrive before this method resumes -- in
      // which case _resolveDuplicateLink would remove a link that this method
      // then puts straight back, leaving the pair permanently double-linked.
      // A conservative 20B write limit holds until the real one is known.
      final link = _OutboundLink(
        peripheral: peripheral,
        tx: tx,
        rx: rx,
        maxWrite: 20,
      );
      _links[key] = link;

      if (!_connected.contains(key)) {
        _links.remove(key);
        _dialling.remove(key);
        _log(LogLevel.info, 'peer ${_short(key)} vanished before subscribe');
        return;
      }
      await _central.setCharacteristicNotifyState(peripheral, tx, state: true);

      try {
        link.maxWrite = await _central.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
      } catch (err) {
        _log(LogLevel.warn,
            'write limit unknown (${_brief(err)}), assuming 20B');
      }

      // The dedupe may have released this link while we were awaiting above.
      if (!_links.containsKey(key)) {
        _log(LogLevel.info, 'peer ${_short(key)} released during setup');
        return;
      }
      _log(
        LogLevel.info,
        'peer ${_short(key)} ready, subscribed, '
        'write limit ${link.maxWrite}B',
      );
      await _sendHelloOutbound(link);
    } catch (err) {
      _log(LogLevel.error, 'setup ${_short(key)}: ${_brief(err)}');
      if (!_yieldedKeys.contains(key)) _dialling.remove(key);
    }
  }

  Future<void> dispose() async {
    _sessionSweep?.cancel();
    _announceTimer?.cancel();
    for (final r in _pendingRelays.values) {
      r.timer?.cancel();
    }
    _pendingRelays.clear();
    for (final t in _pruneTimers.values) {
      t.cancel();
    }
    _pruneTimers.clear();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _logs.close();
    await _messages.close();
  }
}

/// A peer the radio can see right now, linked or not.
class ObservedPeer {
  ObservedPeer({required this.key, required this.name, required this.rssi})
      : lastSeen = DateTime.now();

  final String key;
  final String? name;
  int rssi;
  DateTime lastSeen;

  /// Advertised name if we got one, otherwise the tail of the transport key.
  /// Android cannot advertise a custom name, so this is often the adapter name.
  String get label =>
      name ?? (key.length <= 8 ? key : key.substring(key.length - 8));

  Duration get age => DateTime.now().difference(lastSeen);
}

/// One chosen way to reach one peer: an outbound link we write to, or an
/// inbound central we notify.
class _Target {
  _Target.outbound(this.key, _OutboundLink this.link)
      : central = null,
        maxLength = link.maxWrite;

  _Target.inbound(this.key, Central this.central, this.maxLength) : link = null;

  final String key;
  final _OutboundLink? link;
  final Central? central;
  final int maxLength;
}

/// A relay held back during its random assessment delay.
class _PendingRelay {
  _PendingRelay({required this.forward, required this.fromKey});

  final Uint8List forward;
  final String fromKey;

  /// How many times this frame arrived from someone else while we waited. Each
  /// one is evidence that our own rebroadcast would be redundant.
  int heardFromOthers = 0;
  Timer? timer;
}
