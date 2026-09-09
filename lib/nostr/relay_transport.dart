import 'package:nostr/nostr.dart';

import 'relay_client.dart';

/// What the bridge needs from a relay, whether that is one relay or several.
///
/// Exists so a pool can stand in for a single client without the bridge
/// knowing which it has. Dart has no structural typing, so the shared surface
/// has to be written down.
abstract class RelayTransport {
  Stream<Event> get events;

  Stream<PublishResult> get results;

  Stream<String> get notices;

  /// True when at least one relay is reachable, false when none are.
  Stream<bool> get connectionChanges;

  bool get isConnected;

  void open();

  String subscribe(List<Filter> filters, {String? subscriptionId});

  void unsubscribe(String subscriptionId);

  void publish(Event event);

  Future<void> close();
}
