import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/mesh_link.dart';

/// One bubble in the chat list.
class ChatEntry {
  ChatEntry({required this.text, required this.mine, required this.detail});

  final String text;
  final bool mine;
  final String detail;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _link = MeshLink();
  final _input = TextEditingController();
  final _logScroll = ScrollController();
  final _logs = <LogLine>[];
  final _chat = <ChatEntry>[];

  late final StreamSubscription<LogLine> _logSub;
  late final StreamSubscription<InboundMessage> _msgSub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _logs.addAll(_link.history);

    _logSub = _link.logs.listen((line) {
      setState(() {
        _logs.add(line);
        if (_logs.length > 400) _logs.removeAt(0);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });

    _msgSub = _link.messages.listen((msg) {
      setState(() {
        _chat.add(
          ChatEntry(
            text: msg.text,
            mine: false,
            detail: '${msg.via} · ${msg.peer}',
          ),
        );
      });
    });
  }

  @override
  void dispose() {
    _logSub.cancel();
    _msgSub.cancel();
    _link.dispose();
    _input.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      if (_link.running) {
        await _link.stop();
      } else {
        await _link.start();
      }
    } catch (_) {
      // Already logged by MeshLink. The log pane is the source of truth.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    setState(() {
      _chat.add(
        ChatEntry(
          text: text,
          mine: true,
          detail: '${_link.outboundPeers + _link.inboundPeers} peer(s)',
        ),
      );
    });
    await _link.send(text);
    if (mounted) setState(() {});
  }

  Color _logColour(LogLevel level, ColorScheme scheme) => switch (level) {
        LogLevel.error => scheme.error,
        LogLevel.warn => Colors.orange.shade800,
        LogLevel.tx => Colors.blue.shade700,
        LogLevel.rx => Colors.green.shade700,
        LogLevel.info => scheme.onSurfaceVariant,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = _link.running;
    final peers = _link.outboundPeers + _link.inboundPeers;

    return Scaffold(
      appBar: AppBar(
        title: Text('mesh chat · ${_link.nodeId}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _toggle,
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? 'Stop' : 'Start'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Chip(
                  label: 'adapter ${_link.adapterState}',
                  ok: _link.adapterState == 'poweredOn',
                ),
                _Chip(
                    label: 'out ${_link.outboundPeers}',
                    ok: _link.outboundPeers > 0),
                _Chip(
                    label: 'in ${_link.inboundPeers}',
                    ok: _link.inboundPeers > 0),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _chat.isEmpty
                ? Center(
                    child: Text(
                      running
                          ? peers == 0
                              ? 'Waiting for a peer.\nStart the app on '
                                  'another phone.'
                              : 'Linked to $peers peer(s).\nSend something.'
                          : 'Press Start on every phone.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _chat.length,
                    itemBuilder: (context, i) {
                      final e = _chat[i];
                      return Align(
                        alignment: e.mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          constraints: const BoxConstraints(maxWidth: 280),
                          decoration: BoxDecoration(
                            color: e.mine
                                ? scheme.primaryContainer
                                : scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.text),
                              const SizedBox(height: 2),
                              Text(
                                e.detail,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: running,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'message',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: running ? _send : null,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: (MediaQuery.sizeOf(context).height * 0.26).clamp(110, 190),
            child: Container(
              color: scheme.surfaceContainerLow,
              child: ListView.builder(
                controller: _logScroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                itemCount: _logs.length,
                itemBuilder: (context, i) {
                  final l = _logs[i];
                  return Text(
                    '${l.stamp}  ${l.text}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.5,
                      color: _logColour(l.level, scheme),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ok ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
    );
  }
}
