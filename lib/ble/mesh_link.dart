import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'link_ids.dart';

enum LogLevel { info, tx, rx, warn, error }

/// One line in the in-app log.
///
/// A mesh runs on two or more phones at once, and you cannot attach a debugger
/// to two phones at the same time. So the log goes on the screen.
class LogLine {
  LogLine(this.level, this.text) : time = DateTime.now();

  final DateTime time;
  final LogLevel level;
  final String text;

  String get stamp => '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';
}

/// A message that arrived from another phone.
class InboundMessage {
  InboundMessage({required this.text, required this.peer, required this.via});

  final String text;

  /// Which peer handed it to us.
  final String peer;

  /// How it reached us: `write` if we are the peripheral, `notify` if we are
  /// the central.
  final String via;
}

/// A peer we connected out to, so we are the central and it is the peripheral.
class _OutboundLink {
  _OutboundLink({
    required this.peripheral,
    required this.rx,
    required this.maxWrite,
  });

  final Peripheral peripheral;

  /// The characteristic we write to in order to send.
  final GATTCharacteristic rx;

  /// Largest payload this connection will accept in one write.
  int maxWrite;
}

/// One phone in the mesh, running both GATT roles at the same time.
class MeshLink {
  MeshLink() : nodeId = newNodeId() {
    _wirePeripheral();
    _wireCentral();
  }

  /// Short id for this phone, shown in the app bar and in the logs.
  final String nodeId;

  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();

  final _serviceUuid = UUID.fromString(kServiceUuidString);
  final _txUuid = UUID.fromString(kTxCharacteristicUuidString);
  final _rxUuid = UUID.fromString(kRxCharacteristicUuidString);

  /// Our own TX characteristic. Kept because notifying needs the object, not
  /// just the UUID.
  GATTCharacteristic? _myTx;

  /// Peers we dialled, keyed by the peripheral's uuid.
  final Map<String, _OutboundLink> _links = {};

  /// Peers that dialled us and subscribed to our TX, so we can notify them.
  final Map<String, Central> _centrals = {};
  final Map<String, int> _notifyLimit = {};

  /// Peers we have a connection attempt in flight for, so discovery does not
  /// dial the same phone over and over.
  final Set<String> _dialling = {};

  final _logs = StreamController<LogLine>.broadcast();
  final _messages = StreamController<InboundMessage>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Log lines emitted before the UI subscribed. A broadcast stream drops
  /// events when nobody is listening, and the earliest lines are often the
  /// most useful ones.
  final List<LogLine> _history = [];

  bool _running = false;

  Stream<LogLine> get logs => _logs.stream;
  Stream<InboundMessage> get messages => _messages.stream;
  List<LogLine> get history => List.unmodifiable(_history);
  bool get running => _running;

  /// Adapter state as plain text, so the UI never has to import the plugin.
  String get adapterState => _central.state.name;

  int get outboundPeers => _links.length;
  int get inboundPeers => _centrals.length;

  void _log(LogLevel level, String text) {
    // TODO (Part 4): mirror this to the platform log as well, so it can be
    // read with `adb logcat` instead of by scrolling a phone screen.
    final line = LogLine(level, text);
    _history.add(line);
    if (_history.length > 400) _history.removeAt(0);
    if (!_logs.isClosed) _logs.add(line);
  }

  /// Short label for a peer. Android builds a peer's uuid from its MAC address
  /// and pads the front with zeros, so the first characters are useless. Take
  /// the tail.
  static String _short(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(uuid.length - 8);

  // ------------------------------------------------------------------ startup

  /// Brings up both GATT roles: advertise so others can find us, and scan so we
  /// can find them.
  Future<void> start() async {
    if (_running) return;

    if (!await _authorize()) return;

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

    await _peripheral.removeAllServices();
    await _peripheral.addService(
      GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [tx, rx],
      ),
    );

    await _peripheral.startAdvertising(
      Advertisement(
        name: Platform.isAndroid ? null : '$kNamePrefix$nodeId',
        serviceUUIDs: [_serviceUuid],
      ),
    );
    _log(LogLevel.info, 'advertising');

    await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
    _log(LogLevel.info, 'scanning for ${kServiceUuidString.substring(0, 8)}');

    _running = true;
  }

  /// Asks for permission on Android, then waits for the adapter to actually be
  /// on. Permission being granted and the radio being powered on are two
  /// different things, and starting the GATT server against an adapter that is
  /// off throws a bare platform exception that tells you nothing.
  Future<bool> _authorize() async {
    if (Platform.isAndroid) {
      for (final manager in [_central, _peripheral]) {
        if (manager.state == BluetoothLowEnergyState.unauthorized) {
          final granted = await manager.authorize();
          _log(
            granted ? LogLevel.info : LogLevel.warn,
            'permission granted: $granted',
          );
        }
      }
    }

    if (_central.state == BluetoothLowEnergyState.poweredOn) return true;

    try {
      await _central.stateChanged
          .firstWhere((e) => e.state == BluetoothLowEnergyState.poweredOn)
          .timeout(const Duration(seconds: 6));
      return true;
    } catch (_) {
      _log(
        LogLevel.warn,
        'adapter is ${_central.state.name}, switch Bluetooth on and try again',
      );
      return false;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    for (final link in _links.values) {
      try {
        await _central.disconnect(link.peripheral);
      } catch (_) {
        // Already gone. Nothing to do.
      }
    }
    _links.clear();
    _centrals.clear();
    _notifyLimit.clear();
    _dialling.clear();

    try {
      await _central.stopDiscovery();
      await _peripheral.stopAdvertising();
      await _peripheral.removeAllServices();
    } catch (e) {
      _log(LogLevel.warn, 'while stopping: $e');
    }

    _log(LogLevel.info, 'stopped');
  }

  // --------------------------------------------------------------------- send

  /// Sends [text] to every connected peer.
  ///
  /// Two different paths, because the direction decides the mechanism. To a
  /// peer we dialled we are the central, so we write to its RX. To a peer that
  /// dialled us we are the peripheral, so we notify on our own TX.
  Future<void> send(String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    _log(
      LogLevel.tx,
      'send ${bytes.length}B to ${_links.length + _notifyLimit.length} peer(s)',
    );

    for (final link in _links.values.toList()) {
      if (bytes.length > link.maxWrite) {
        _log(
            LogLevel.warn, 'too long for ${_short('${link.peripheral.uuid}')}');
        continue;
      }
      try {
        await _central.writeCharacteristic(
          link.peripheral,
          link.rx,
          value: bytes,
          type: GATTCharacteristicWriteType.withResponse,
        );
      } catch (e) {
        // TODO (Part 4): clip this to the first line. A Java stack trace in a
        // small log pane buries the one line that matters.
        _log(LogLevel.error, 'write failed: $e');
      }
    }

    final tx = _myTx;
    if (tx == null) return;
    for (final entry in _notifyLimit.entries.toList()) {
      final central = _centrals[entry.key];
      if (central == null) continue;
      if (bytes.length > entry.value) {
        _log(LogLevel.warn, 'too long for ${_short(entry.key)}');
        continue;
      }
      try {
        await _peripheral.notifyCharacteristic(central, tx, value: bytes);
      } catch (e) {
        _log(LogLevel.error, 'notify failed: $e');
      }
    }
  }

  void _receive(Uint8List bytes, String via, String key) {
    final text = utf8.decode(bytes, allowMalformed: true);
    _log(LogLevel.rx, 'recv ${bytes.length}B via $via');
    if (_messages.isClosed) return;
    _messages.add(
      InboundMessage(text: text, peer: _short(key), via: via),
    );
  }

  // -------------------------------------------------------- peripheral wiring

  void _wirePeripheral() {
    // TODO (Part 4): guard every one of these subscriptions. Some of these
    // streams do not exist on every platform, and touching one that does not
    // takes the whole app down before it draws a single frame.
    _subs.add(
      _peripheral.stateChanged.listen((e) {
        _log(LogLevel.info, 'peripheral adapter ${e.state.name}');
      }),
    );

    _subs.add(
      _peripheral.characteristicNotifyStateChanged.listen((e) async {
        if (e.characteristic.uuid != _txUuid) return;
        final key = '${e.central.uuid}';
        if (e.state) {
          _centrals[key] = e.central;
          final limit = await _peripheral.getMaximumNotifyLength(e.central);
          _notifyLimit[key] = limit;
          _log(LogLevel.info, 'central ${_short(key)} subscribed, ${limit}B');
        } else {
          _centrals.remove(key);
          _notifyLimit.remove(key);
          _log(LogLevel.info, 'central ${_short(key)} unsubscribed');
        }
      }),
    );

    _subs.add(
      _peripheral.characteristicWriteRequested.listen((e) async {
        // Answer first. A write request that is left unanswered blocks the
        // sender's queue, and a blocked queue looks exactly like a dead link.
        try {
          await _peripheral.respondWriteRequest(e.request);
        } catch (err) {
          _log(LogLevel.error, 'respond failed: $err');
        }
        if (e.characteristic.uuid != _rxUuid) return;
        _receive(e.request.value, 'write', '${e.central.uuid}');
      }),
    );
  }

  // ----------------------------------------------------------- central wiring

  void _wireCentral() {
    _subs.add(
      _central.stateChanged.listen((e) {
        _log(LogLevel.info, 'central adapter ${e.state.name}');
      }),
    );

    _subs.add(
      _central.discovered.listen((e) async {
        final key = '${e.peripheral.uuid}';
        if (_links.containsKey(key) || _dialling.contains(key)) return;
        _dialling.add(key);
        _log(LogLevel.info, 'dialling ${_short(key)} (rssi ${e.rssi})');
        try {
          await _central.connect(e.peripheral);
        } catch (err) {
          _dialling.remove(key);
          _log(LogLevel.error, 'connect failed: $err');
        }
      }),
    );

    _subs.add(
      _central.connectionStateChanged.listen((e) async {
        final key = '${e.peripheral.uuid}';
        if (e.state == ConnectionState.connected) {
          await _setUpOutbound(e.peripheral);
        } else {
          _links.remove(key);
          _dialling.remove(key);
          _log(LogLevel.info, 'peer ${_short(key)} disconnected');
        }
      }),
    );

    _subs.add(
      _central.characteristicNotified.listen((e) {
        if (e.characteristic.uuid != _txUuid) return;
        _receive(e.value, 'notify', '${e.peripheral.uuid}');
      }),
    );
  }

  /// Finds our service on a freshly connected peer, subscribes to its TX so it
  /// can talk to us, and reads the real write limit for this connection.
  Future<void> _setUpOutbound(Peripheral peripheral) async {
    final key = '${peripheral.uuid}';
    try {
      if (Platform.isAndroid) {
        try {
          final mtu = await _central.requestMTU(peripheral, mtu: 517);
          _log(LogLevel.info, 'negotiated mtu $mtu');
        } catch (err) {
          _log(LogLevel.warn, 'requestMTU: $err');
        }
      }

      final services = await _central.discoverGATT(peripheral);
      GATTService? service;
      for (final s in services) {
        if (s.uuid == _serviceUuid) service = s;
      }
      if (service == null) {
        _log(LogLevel.error, 'no mesh service on ${_short(key)}');
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
        _log(LogLevel.error, 'characteristics missing on ${_short(key)}');
        _dialling.remove(key);
        await _central.disconnect(peripheral);
        return;
      }

      await _central.setCharacteristicNotifyState(peripheral, tx, state: true);

      var maxWrite = 20;
      try {
        maxWrite = await _central.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
      } catch (err) {
        _log(LogLevel.warn, 'write limit unknown, assuming 20B');
      }

      _links[key] = _OutboundLink(
        peripheral: peripheral,
        rx: rx,
        maxWrite: maxWrite,
      );
      _log(LogLevel.info, 'peer ${_short(key)} ready, ${maxWrite}B');
    } catch (err) {
      _dialling.remove(key);
      _log(LogLevel.error, 'setup failed: $err');
    }
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _logs.close();
    await _messages.close();
  }
}
