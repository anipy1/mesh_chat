import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';

import '../ble/frame.dart';
import '../ble/link_ids.dart';
import '../ble/mesh_link.dart';

class ChatEntry {
  ChatEntry({
    required this.text,
    required this.mine,
    required this.detail,
  }) : time = DateTime.now();
  final String text;
  final bool mine;
  final String detail;
  final DateTime time;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _link = MeshLink();
  final _input = TextEditingController();
  final _logs = <LogLine>[];
  final _chat = <ChatEntry>[];
  final _logScroll = ScrollController();
  late final StreamSubscription _logSub;
  late final StreamSubscription _msgSub;
  Timer? _tick;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _logs.addAll(_link.history); // replay what happened before we subscribed
    // RSSI and "last seen" only mean something if they move.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
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
            // MeshLink only surfaces frames it can render now; unknown
            // types are logged and relayed, never shown.
            text: msg.frame.text,
            mine: false,
            detail: () {
              final hops = Frame.defaultTtl - msg.frame.ttl;
              final path = hops <= 0 ? 'direct' : '$hops hop';
              return '${msg.via} · ${msg.peer} · $path · ttl ${msg.frame.ttl}';
            }(),
          ),
        );
      });
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
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
      if (_link.running || _link.wantRunning) {
        await _link.stop();
      } else {
        await _link.start();
      }
    } catch (_) {
      // Already logged by MeshLink; the log pane is the source of truth.
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
          detail: '${_link.outboundPeers} out · '
              '${_link.subscribedCentrals} sub',
        ),
      );
    });
    await _link.send(text);
    if (mounted) setState(() {});
  }

  /// Blocking a peer is how an A-B-C line topology is made on one desk: the
  /// radio still sees it, the protocol pretends it cannot.
  Future<void> _openBlockSheet() async {
    final input = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final candidates = <String>{
            ..._link.knownPeers,
            ..._link.blocked,
          }.toList()
            ..sort();
          return AlertDialog(
            title: const Text('Simulate out of range'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'A blocked peer is ignored in both directions, so you can '
                    'build an A-B-C line on one table.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  if (candidates.isEmpty)
                    const Text('No peers seen yet.',
                        style: TextStyle(fontSize: 12)),
                  for (final id in candidates)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(id,
                          style: const TextStyle(fontFamily: 'monospace')),
                      value: _link.blocked.contains(id),
                      onChanged: (v) => setSheet(() {
                        if (v ?? false) {
                          _link.block(id);
                        } else {
                          _link.unblock(id);
                        }
                      }),
                    ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: input,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'node id',
                            helperText: 'block before meeting it',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          final id = input.text.trim().toUpperCase();
                          if (id.isEmpty) return;
                          setSheet(() => _link.block(id));
                          input.clear();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
    input.dispose();
    if (mounted) setState(() {});
  }

  Color _logColor(LogLevel level, ColorScheme scheme) => switch (level) {
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
    // Start pressed while the adapter was off: intent is held and the stack
    // comes up by itself, so the button must offer a way out.
    final pending = _link.wantRunning && !running;

    return Scaffold(
      appBar: AppBar(
        title: Text('mesh spike · ${_link.nodeId}'),
        actions: [
          IconButton(
            tooltip: 'Simulate out of range',
            onPressed: _openBlockSheet,
            icon: Badge(
              isLabelVisible: _link.blocked.isNotEmpty,
              label: Text('${_link.blocked.length}'),
              child: const Icon(Icons.block),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _toggle,
              icon: Icon(
                running || pending ? Icons.stop : Icons.play_arrow,
              ),
              label: Text(
                running
                    ? 'Stop'
                    : pending
                        ? 'Waiting'
                        : 'Start',
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusStrip(link: _link),
          const Divider(height: 1),
          Expanded(
            flex: 3,
            child: _chat.isEmpty
                ? Center(
                    child: Text(
                      !running && _link.wantRunning
                          ? (_link.state == BluetoothLowEnergyState.poweredOn
                              ? 'Adapter is on but the stack did not come up.'
                                  '\nSee the log below.'
                              : 'Bluetooth is ${_link.state.name}.'
                                  '\nTurn it on and this will start itself.')
                          : !running
                              ? 'Press Start on every device.'
                              : _link.peerLabels.isEmpty
                                  ? 'Waiting for a peer.\nStart the app on '
                                      'another device.'
                                  : 'Linked to ${_link.knownPeers.isEmpty ? _link.peerLabels.length : _link.knownPeers.length} peer(s).'
                                      '\nSend something.',
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
                      color: _logColor(l.level, scheme),
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

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.link});
  final MeshLink link;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Chip(
                label: 'adapter ${link.state.name}',
                ok: link.state.name == 'poweredOn',
              ),
              _Chip(
                  label: 'out ${link.outboundPeers}',
                  ok: link.outboundPeers > 0),
              _Chip(
                  label: 'in ${link.inboundPeers}', ok: link.inboundPeers > 0),
              _Chip(
                label: 'sub ${link.subscribedCentrals}',
                ok: link.subscribedCentrals > 0,
              ),
              _Chip(
                label: 'relay ${link.relayedCount}/'
                    '${link.relayedCount + link.suppressedCount}',
                ok: link.relayedCount > 0 || link.suppressedCount > 0,
              ),
              _Chip(label: 'env v${Frame.envelopeVersion}', ok: true),
            ],
          ),
          // Radio-visible peers, linked or not. For the control experiment this
          // is the line that matters: if C never shows up here, C is genuinely
          // out of range, and that is an observation rather than an inference.
          if (link.observed.isNotEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 20,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final o in link.observed)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        '${o.label} ${o.rssi}dBm ${o.age.inSeconds}s'
                        '${link.blocked.contains(o.label.replaceFirst(kNamePrefix, '')) ? ' [blocked]' : ''}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: o.age.inSeconds > 10
                              ? scheme.outline
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (link.peerLabels.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              link.peerLabels.join('   '),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
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
