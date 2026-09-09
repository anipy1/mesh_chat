import 'package:web_socket_channel/web_socket_channel.dart';

/// A connection to one relay, reduced to the three things a client needs.
///
/// A seam rather than a direct dependency on the socket package, for the same
/// reason the seed vault has one: the logic worth testing is what happens to
/// malformed messages, dropped connections and out of order replies, and none
/// of that has anything to do with WebSockets. Faking a WebSocketChannel means
/// pinning ourselves to whichever version we wrote against.
abstract class RelaySocket {
  Stream<String> get messages;

  void send(String data);

  Future<void> close();
}

/// Opens a socket to [url].
typedef RelaySocketFactory = RelaySocket Function(Uri url);

/// The real one.
class WebSocketRelaySocket implements RelaySocket {
  WebSocketRelaySocket(Uri url) : _channel = WebSocketChannel.connect(url);

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages =>
      _channel.stream.map((event) => event is String ? event : '$event');

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      // A socket that is already gone is the outcome we wanted.
    }
  }
}
