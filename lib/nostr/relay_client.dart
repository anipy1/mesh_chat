import 'dart:async';
import 'dart:convert';

import 'package:nostr/nostr.dart';

import 'relay_socket.dart';
import 'relay_transport.dart';

/// What a relay said about an event we published.
class PublishResult {
  const PublishResult(this.eventId, this.accepted, this.message);

  final String eventId;
  final bool accepted;
  final String message;
}

/// One relay, kept connected.
///
/// Deliberately thin. The nostr package already turns a relay's JSON into
/// typed messages, so the only real work here is the socket: staying
/// connected, restoring subscriptions afterwards, and not falling over when a
/// relay sends something unexpected.
///
/// Public relays drop connections routinely, for idleness, restarts or their
/// own rate limits, and none of that is exceptional enough to surface to a
/// user. So a drop reconnects with backoff and re-sends the subscriptions,
/// rather than being reported as an error.
class RelayClient implements RelayTransport {
  RelayClient(
    this.url, {
    RelaySocketFactory? connect,
    this.secretKey,
    this.retryBase = const Duration(seconds: 1),
    this.retryCap = const Duration(seconds: 30),
  }) : _connect = connect ?? ((u) => WebSocketRelaySocket(u));

  final Uri url;
  final RelaySocketFactory _connect;

  /// Hex secret key used to answer a NIP-42 challenge, when there is one.
  ///
  /// Relays that carry private messages generally demand this before they will
  /// serve gift wraps, and they are right to: without it anyone could subscribe
  /// to kind 1059 by recipient and learn who is receiving messages, which is
  /// most of what the encryption was hiding. relay.damus.io answers such a
  /// subscription with "auth-required: requested filter requires
  /// authentication".
  ///
  /// Null means read what is public and publish, but do not expect to read
  /// anything addressed to us.
  final String? secretKey;

  /// Backoff, doubling from [retryBase] up to [retryCap]. A relay that is down
  /// stays down for a while, and hammering it is both rude and useless.
  final Duration retryBase;
  final Duration retryCap;

  RelaySocket? _socket;
  StreamSubscription<String>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _closed = false;
  bool _authenticated = false;
  bool _authAttempted = false;
  String? _authEventId;

  /// Subscriptions we have asked for, so they can be restored after a drop.
  ///
  /// A relay remembers nothing across connections, so a reconnect that did not
  /// re-send these would leave the app silently waiting for messages that were
  /// never subscribed to.
  final Map<String, List<Filter>> _subscriptions = {};

  final _events = StreamController<Event>.broadcast();
  final _results = StreamController<PublishResult>.broadcast();
  final _notices = StreamController<String>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  /// Events the relay sent for any of our subscriptions.
  @override
  Stream<Event> get events => _events.stream;

  /// One per published event, when the relay bothers to say.
  @override
  Stream<PublishResult> get results => _results.stream;

  /// Anything the relay wants to tell a human. Worth surfacing: this is where
  /// rate limits and rejections get explained.
  @override
  Stream<String> get notices => _notices.stream;

  @override
  Stream<bool> get connectionChanges => _connected.stream;

  @override
  bool get isConnected => _socket != null;

  @override
  void open() {
    if (_closed) throw StateError('this client has been closed');
    _openSocket();
  }

  void _openSocket() {
    _retry?.cancel();
    try {
      final socket = _connect(url);
      _socket = socket;
      _sub = socket.messages.listen(
        _onMessage,
        onError: (Object _) => _onDisconnected(),
        onDone: _onDisconnected,
        cancelOnError: true,
      );
      _attempt = 0;
      _connected.add(true);
      // Anything asked for before the socket existed, or before it dropped.
      for (final entry in _subscriptions.entries) {
        _sendRequest(entry.key, entry.value);
      }
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onDisconnected() {
    _sub?.cancel();
    _sub = null;
    _socket = null;
    _authenticated = false;
    _authAttempted = false;
    _authEventId = null;
    if (_closed) return;
    _connected.add(false);

    final shift = _attempt > 5 ? 5 : _attempt;
    final wait = retryBase * (1 << shift);
    _attempt++;
    _retry = Timer(wait > retryCap ? retryCap : wait, _openSocket);
  }

  void _onMessage(String payload) {
    final Message message;
    try {
      message = Message.deserialize(payload);
    } catch (_) {
      // A relay sending something we cannot parse is its problem, not a reason
      // to drop a working connection. Some send NIPs we do not implement.
      return;
    }

    switch (message.messageType) {
      case MessageType.event:
        final event = message.message as Event;
        if (!_events.isClosed) _events.add(event);
      case MessageType.ok:
        final ok = message.message as Nip20;
        if (ok.eventId == _authEventId) {
          // The verdict on our own AUTH, not on a message. Some relays reject
          // it for reasons of their own: relay.damus.io answers "relay needs
          // serviceUrl to be configured before AUTH can work", which is its
          // configuration rather than our request. Either way there is nothing
          // to retry, so say so once and stop.
          _authenticated = ok.status;
          if (!_notices.isClosed) {
            _notices.add(
              ok.status ? 'authenticated' : 'auth refused: ${ok.message}',
            );
          }
          return;
        }
        if (!_results.isClosed) {
          _results.add(PublishResult(ok.eventId, ok.status, ok.message));
        }
      case MessageType.notice:
        if (!_notices.isClosed) _notices.add('${message.message}');
      case MessageType.closed:
        // The package hands CLOSED back as a plain map rather than a type.
        final closed = message.message as Map<String, dynamic>;
        final id = closed['subscriptionId'];
        final why = '${closed['message']}';
        // A subscription refused for want of authentication is kept, not
        // dropped. The relay is about to send a challenge, or already has, and
        // the same subscription will be accepted once it is answered.
        // Forgetting it here would mean the retry after AUTH asks for nothing.
        if (id is String && !why.contains('auth-required')) {
          _subscriptions.remove(id);
        }
        if (!_notices.isClosed) _notices.add('subscription closed: $why');
      case MessageType.auth:
        _answerChallenge('${message.message}');
      case MessageType.eose:
        // Stored events are done and live ones follow. Nothing to do: this
        // client does not distinguish the two.
        break;
      default:
        break;
    }
  }

  /// Answers a NIP-42 challenge and asks again for everything.
  ///
  /// The relay sends the challenge whenever it likes, including after a
  /// subscription has already been refused, so the subscriptions are re-sent
  /// once the reply is away rather than waiting to be asked a second time.
  void _answerChallenge(String raw) {
    // Once per connection, and no more. A relay is free to re-challenge
    // whenever it likes, and answering every time turned into a tight loop
    // against a public relay: challenge, answer, re-subscribe, refused,
    // challenge again. Ten rounds in a couple of seconds, which is rude at
    // best and a good way to be rate limited at worst.
    if (_authAttempted) return;
    _authAttempted = true;

    final key = secretKey;
    if (key == null) {
      if (!_notices.isClosed) {
        _notices.add('relay asked for auth and we have no key for it');
      }
      return;
    }

    // The package hands the AUTH payload back as a JSON encoded list.
    String? challenge;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.isNotEmpty) challenge = '${decoded.first}';
    } catch (_) {
      challenge = raw;
    }
    if (challenge == null || challenge.isEmpty) return;

    final event = RelayAuth.create(
      challenge: challenge,
      relayUrl: url.toString(),
      secretKey: key,
    );
    _authEventId = event.id;
    _send(jsonEncode(['AUTH', event.toMap()]));

    for (final entry in _subscriptions.entries) {
      _sendRequest(entry.key, entry.value);
    }
  }

  /// Whether we have answered a challenge on this connection. Reset on a drop,
  /// because a relay's authenticated session lasts exactly as long as the
  /// socket does.
  bool get isAuthenticated => _authenticated;

  /// Publishes [event]. Returns immediately; watch [results] for the verdict.
  @override
  void publish(Event event) => _send(event.serialize());

  /// Subscribes with [filters] and returns the subscription id.
  ///
  /// Recorded before sending, so a subscription asked for while disconnected
  /// still goes out when the socket comes back.
  @override
  String subscribe(List<Filter> filters, {String? subscriptionId}) {
    final id = subscriptionId ?? generateRandomHex(bytes: 16);
    _subscriptions[id] = filters;
    _sendRequest(id, filters);
    return id;
  }

  @override
  void unsubscribe(String subscriptionId) {
    _subscriptions.remove(subscriptionId);
    _send(Close(subscriptionId).serialize());
  }

  void _sendRequest(String id, List<Filter> filters) =>
      _send(Request(subscriptionId: id, filters: filters).serialize());

  void _send(String payload) {
    final socket = _socket;
    if (socket == null) return; // reconnect will restore subscriptions
    try {
      socket.send(payload);
    } catch (_) {
      _onDisconnected();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _sub?.cancel();
    await _socket?.close();
    _socket = null;
    await _events.close();
    await _results.close();
    await _notices.close();
    await _connected.close();
  }
}
