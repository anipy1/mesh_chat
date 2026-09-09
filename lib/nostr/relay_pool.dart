import 'dart:async';

import 'package:nostr/nostr.dart';

import 'relay_client.dart';
import 'relay_transport.dart';

/// Several relays behaving as one.
///
/// A single relay is a single point of failure for the whole internet path,
/// which is most of what the internet path was for. Nostr's own answer is to
/// use a handful and treat them as interchangeable: publish to all of them,
/// read from all of them, and expect any one to be down at any time.
///
/// Redundancy here is deliberate duplication rather than load spreading. The
/// same message goes to every relay, because the point is that losing one
/// changes nothing.
class RelayPool implements RelayTransport {
  RelayPool(this.clients);

  /// Builds a pool over [urls], each with the same key for NIP-42.
  factory RelayPool.forUrls(List<Uri> urls, {String? secretKey}) => RelayPool(
        urls.map((u) => RelayClient(u, secretKey: secretKey)).toList(),
      );

  final List<RelayClient> clients;

  /// Event ids already handed on, so the same message arriving from four
  /// relays is only dealt with once.
  ///
  /// The mesh dedupes frames by message id anyway, so this is not about
  /// correctness. It is about not unwrapping the same gift wrap four times,
  /// and unwrapping costs a key exchange.
  final Set<String> _seen = {};
  static const _seenCap = 512;

  final _events = StreamController<Event>.broadcast();
  final _results = StreamController<PublishResult>.broadcast();
  final _notices = StreamController<String>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];

  bool _lastReported = false;

  @override
  Stream<Event> get events => _events.stream;

  @override
  Stream<PublishResult> get results => _results.stream;

  @override
  Stream<String> get notices => _notices.stream;

  @override
  Stream<bool> get connectionChanges => _connected.stream;

  /// Up if any relay is up. One reachable relay is a working internet path.
  @override
  bool get isConnected => clients.any((c) => c.isConnected);

  /// How many are currently reachable, for a UI that wants to be honest about
  /// the difference between "one of four" and "four of four".
  int get connectedCount => clients.where((c) => c.isConnected).length;

  int get relayCount => clients.length;

  @override
  void open() {
    for (final client in clients) {
      _subs.add(client.events.listen(_onEvent));
      _subs.add(client.results.listen((r) {
        if (!_results.isClosed) _results.add(r);
      }));
      _subs.add(client.notices.listen((n) {
        // Named, because "auth refused" from one relay of four is a very
        // different situation from all of them refusing.
        if (!_notices.isClosed) _notices.add('${client.url}: $n');
      }));
      _subs.add(client.connectionChanges.listen((_) => _reportConnection()));
      client.open();
    }
  }

  void _onEvent(Event event) {
    if (!_seen.add(event.id)) return;
    if (_seen.length > _seenCap) _seen.remove(_seen.first);
    if (!_events.isClosed) _events.add(event);
  }

  /// Reports the pool as up or down, not each relay's own state.
  ///
  /// A caller wants to know whether it has an internet path at all, and would
  /// otherwise see it flap every time one of four relays reconnects.
  void _reportConnection() {
    final up = isConnected;
    if (up == _lastReported) return;
    _lastReported = up;
    if (!_connected.isClosed) _connected.add(up);
  }

  /// Subscribes on every relay under one id, so the same subscription can be
  /// cancelled everywhere by name.
  @override
  String subscribe(List<Filter> filters, {String? subscriptionId}) {
    final id = subscriptionId ?? generateRandomHex(bytes: 16);
    for (final client in clients) {
      client.subscribe(filters, subscriptionId: id);
    }
    return id;
  }

  @override
  void unsubscribe(String subscriptionId) {
    for (final client in clients) {
      client.unsubscribe(subscriptionId);
    }
  }

  /// Publishes to every relay. Deliberately not "the first that works": the
  /// whole reason for a pool is that we cannot tell which one the recipient is
  /// listening to.
  @override
  void publish(Event event) {
    for (final client in clients) {
      client.publish(event);
    }
  }

  @override
  Future<void> close() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    for (final client in clients) {
      await client.close();
    }
    await _events.close();
    await _results.close();
    await _notices.close();
    await _connected.close();
  }
}
