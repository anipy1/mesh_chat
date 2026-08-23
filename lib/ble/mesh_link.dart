import 'dart:async';

// TODO (Part 3): Import the bluetooth_low_energy package

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

/// One phone in the mesh, running both GATT roles at the same time.
class MeshLink {
  MeshLink() : nodeId = newNodeId() {
    // TODO (Part 3): Wire up the peripheral role listeners
    // TODO (Part 3): Wire up the central role listeners
  }

  /// Short id for this phone, shown in the app bar and in the logs.
  final String nodeId;

  // TODO (Part 3): Create the CentralManager and PeripheralManager

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
  String get adapterState {
    // TODO (Part 3): Report the real adapter state
    return 'unknown';
  }

  /// Peers we connected out to, where we are the central.
  int get outboundPeers {
    // TODO (Part 3): Report the number of outbound links
    return 0;
  }

  /// Peers that connected in to us, where we are the peripheral.
  int get inboundPeers {
    // TODO (Part 3): Report the number of inbound centrals
    return 0;
  }

  void _log(LogLevel level, String text) {
    final line = LogLine(level, text);
    _history.add(line);
    if (_history.length > 400) _history.removeAt(0);
    if (!_logs.isClosed) _logs.add(line);
  }

  /// Brings up both GATT roles: advertise so others can find us, and scan so we
  /// can find them.
  Future<void> start() async {
    if (_running) return;

    // TODO (Part 3): Ask for permission and wait for the adapter to power on

    // TODO (Part 3): Build the GATT service with the TX and RX characteristics

    // TODO (Part 3): Start advertising the mesh service

    // TODO (Part 3): Start scanning, filtered on the mesh service

    _running = true;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    // TODO (Part 3): Stop advertising, stop scanning and drop the connections

    _log(LogLevel.info, 'stopped');
  }

  /// Sends [text] to every connected peer.
  Future<void> send(String text) async {
    // TODO (Part 3): Send to every connected peer
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
