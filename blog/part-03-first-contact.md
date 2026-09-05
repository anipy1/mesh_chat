---
title: "Building a BLE mesh messenger in Flutter, Part 3: two phones, one message"
published: false
description: "Both GATT roles at once, permissions on two platforms, and an actual message crossing between an Android phone and an iPhone."
tags: bluetooth, flutter, dart, mesh
series: "Building a BLE mesh messenger in Flutter"
---

Hello everyone! This is [Anipy](https://github.com/anipy1) again, and in this part
we finally write code. By the end you will have two phones sending messages to
each other over Bluetooth, with no server and no internet.

In [Part 2](#) we went through the concepts. The one that matters most here is
that a mesh node has to run **both GATT roles at the same time**, so it is
advertising for others to find and also scanning to find them. Everything in this
part is built around that.

We are also going to end with a bug. Not a mistake I forgot to fix, an actual
design problem that shows up the moment two phones connect, and you will see it in
your own logs. That bug is what Part 6 is about.

## Getting Started

Grab the starter project:

```shell
git clone -b starter --single-branch https://github.com/anipy1/mesh_chat
```

The starter has the whole UI already built, so we can spend this series on the
protocol instead of on widgets. Open it, run `flutter pub get`, and launch it on a
phone. It runs, but the Start button does nothing yet.

Every place we need to write code has a `// TODO (Part 3):` comment sitting in it.
As we go, I will tell you which comment to look for and what to replace it with.
Each branch of the repo is one part finished plus the next part's TODOs, so if you
ever want to skip ahead or check your work, `git checkout part-03` is the finished
version of this article.

## Project Files

A quick tour before we start.

### lib/ble/link_ids.dart

The UUIDs and the node id. This file is already done, but read it, because these
three UUIDs are the whole contract between phones:

```dart
const kServiceUuidString = '6f5d0001-9c4a-4b2e-8f11-2a7c9d3e5b80';
const kTxCharacteristicUuidString = '6f5d0002-9c4a-4b2e-8f11-2a7c9d3e5b80';
const kRxCharacteristicUuidString = '6f5d0003-9c4a-4b2e-8f11-2a7c9d3e5b80';
```

One service and two characteristics, exactly the design we arrived at in Part 2.
TX is the one we notify on, RX is the one others write to. If you are building
your own thing, generate your own UUIDs, do not reuse mine.

There is also `newNodeId()`, which gives this phone a short random id like `5UJE`
on every launch. A fresh id every run is deliberate: it makes the logs
unambiguous about which phone did what. Real identity is a separate problem and it
gets its own part.

### lib/ble/mesh_link.dart

The file we are filling in. It is the only thing we touch in this part.

### lib/ui/home_page.dart

The UI, finished. Status chips, a chat list, a text field, and a log pane along
the bottom.

That log pane is worth a word. A mesh runs on two or more phones at once, and you
cannot attach a debugger to two phones at the same time. So the log goes on the
screen where you can read it while you use the app. It is the single most useful
thing in this project and it gets a whole part of its own.

Notice that `home_page.dart` never imports the Bluetooth package. `MeshLink`
exposes the adapter state as a plain `String`, so the UI has no idea BLE exists.
That means this file stays untouched for the rest of the series.

## Adding the package

We are using [`bluetooth_low_energy`](https://pub.dev/packages/bluetooth_low_energy),
because it does both roles. Most Flutter BLE packages only do the central side,
which is fine for talking to a sensor and useless for a mesh.

Find `# TODO (Part 3): Add the bluetooth_low_energy package here` in
`pubspec.yaml` and replace it with:

```yaml
  bluetooth_low_energy: ^6.2.1
```

Then run `flutter pub get`.

One thing I want to flag, because I nearly got it wrong. There are packages that
do only the peripheral side, and it is tempting to combine one of those with a
central-only package. Do not. On iOS a single `CBPeripheralManager` owns both the
advertising and the list of services you expose, so two packages means two of
those objects, and you end up advertising a service that no GATT server is
actually backing. Other phones connect and find nothing there. One package for
both roles.

## Permissions

This is the part that silently wastes an afternoon if you get it wrong.

In `android/app/src/main/AndroidManifest.xml`, find
`<!-- TODO (Part 3): Add the Bluetooth permissions here -->` and replace it with:

```xml
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

    <uses-permission android:name="android.permission.BLUETOOTH"
        android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
        android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"
        android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
        android:maxSdkVersion="30" />

    <uses-feature android:name="android.hardware.bluetooth_le"
        android:required="true" />
```

There are two groups here because Android split its Bluetooth permissions at
API 31:

- **API 31 and up** uses the three `BLUETOOTH_*` runtime permissions.
  `neverForLocation` on the scan permission is a promise that we are not using
  scan results to work out where the user is, and it means we do not need the
  location permission on those versions.
- **API 30 and below** has no such thing, and instead requires the **location**
  permissions for BLE scanning. Both of them. The plugin asks for coarse and fine
  together on those versions, and a permission you did not declare in the manifest
  can never be granted, so leaving one out makes the whole request fail.

And here is the one that got me. On Android 11 and below, BLE scanning also needs
**location services switched on at the system level**, not just the permission
granted to your app. If the permission is granted and the system toggle is off,
scanning returns absolutely nothing and reports no error at all. It just quietly
finds no devices forever. If you are testing on an older phone and nothing shows
up, check that toggle first.

Now for iOS. In `ios/Runner/Info.plist`, find
`<!-- TODO (Part 3): Add the Bluetooth usage descriptions here -->` and replace it
with:

```xml
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Finds nearby phones so messages can be exchanged directly, with no server and no internet.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>Lets nearby phones find this one so messages can be exchanged directly.</string>
```

iOS shows that first string in the permission dialog, so write something a real
person would understand. The second one is for older iOS versions and costs
nothing to include.

## The two managers

Now `mesh_link.dart`. Find `// TODO (Part 3): Import the bluetooth_low_energy
package` and replace it with:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
```

Next, find `// TODO (Part 3): Create the CentralManager and PeripheralManager` and
replace it with:

```dart
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
```

Two managers, and that is the whole dual role right there. `_central` scans and
connects, `_peripheral` advertises and answers. They are separate objects and both
are live for the entire time the app is running.

Notice we track peers in **two** collections. `_links` is for phones we connected
out to, where we are the central. `_centrals` is for phones that connected in to
us, where we are the peripheral. Same physical phone can be in both, and that is
the thing that bites us at the end of this article.

We also need a small class for an outbound link. Add this above the `MeshLink`
class:

```dart
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
```

Then there are three getters the UI reads, each with a TODO and a placeholder
return. Replace all three of them, from `String get adapterState` down to the
closing brace of `inboundPeers`, with these:

```dart
  /// Adapter state as plain text, so the UI never has to import the plugin.
  String get adapterState => _central.state.name;

  /// Peers we connected out to, where we are the central.
  int get outboundPeers => _links.length;

  /// Peers that connected in to us, where we are the peripheral.
  int get inboundPeers => _centrals.length;
```

Replace the whole getters here rather than just the TODO lines, otherwise the
placeholder `return 0;` underneath stays behind and shadows your new code.

## Turning the radio on

Before we can advertise or scan we need permission, and we need the adapter to
actually be powered on. Those are two different things and I learned that the
annoying way.

Find `// TODO (Part 3): Ask for permission and wait for the adapter to power on`
and replace it with:

```dart
    if (!await _authorize()) return;
```

Now add the `_authorize` method itself, just after `start()`:

```dart
  Future<bool> _authorize() async {
    // 1
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

    // 2
    if (_central.state == BluetoothLowEnergyState.poweredOn) return true;

    // 3
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
```

In the above code:

1. On Android, ask for the runtime permissions if we do not have them. iOS handles
   this itself when you first touch the radio, so there is nothing to do there.
2. If the adapter is already on, we are done.
3. If it is not on, wait up to six seconds for it to come on, then give up with a
   message that actually tells the user what to do.

Step 3 is the important one. `authorize()` returning true only means the
**permission** was granted. The adapter state arrives separately and
asynchronously, so right after the permission dialog the cached state is often
still stale. My first version skipped this wait, and starting the GATT server
against an adapter that was off threw a bare `IllegalStateException` from the
platform channel with no useful message in it. Waiting for `poweredOn` turns that
into a sentence a user can act on.

## The GATT service

Now we build the service from Part 2. Find `// TODO (Part 3): Build the GATT
service with the TX and RX characteristics` and replace it with:

```dart
    // 1
    final tx = GATTCharacteristic.mutable(
      uuid: _txUuid,
      properties: [GATTCharacteristicProperty.notify],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [],
    );
    // 2
    final rx = GATTCharacteristic.mutable(
      uuid: _rxUuid,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    // 3
    _myTx = tx;

    // 4
    await _peripheral.removeAllServices();
    await _peripheral.addService(
      GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [tx, rx],
      ),
    );
```

In the above code:

1. TX is notify only. This is how we, as a peripheral, push data to a central that
   has subscribed. Remember from Part 2 that a peripheral cannot speak first any
   other way.
2. RX is write. This is how a central sends data to us.
3. Keep a reference to TX, because notifying takes the characteristic object.
4. Clear any old services and register ours. `removeAllServices` matters if the
   user presses Stop and Start again, otherwise you end up registering the same
   service twice.

## Advertising and scanning

Find `// TODO (Part 3): Start advertising the mesh service` and replace it with:

```dart
    await _peripheral.startAdvertising(
      Advertisement(
        name: Platform.isAndroid ? null : '$kNamePrefix$nodeId',
        serviceUUIDs: [_serviceUuid],
      ),
    );
    _log(LogLevel.info, 'advertising');
```

That `Platform.isAndroid ? null` looks odd and it is deliberate. On Android this
package implements `Advertisement.name` by renaming the **phone's** Bluetooth
adapter, system wide, and it never puts it back. That is the name your car stereo
and your headphones see, and it is not ours to change. On iOS it sets a real
per-advertisement field with no side effects, so it is fine there. We will put our
identity somewhere sensible in Part 6.

Next, find `// TODO (Part 3): Start scanning, filtered on the mesh service` and
replace it with:

```dart
    await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
    _log(LogLevel.info, 'scanning for ${kServiceUuidString.substring(0, 8)}');
```

Always filter the scan on your service UUID. Without the filter you get told
about every wireless device in the room, and on iOS the filter is the only way to
find a peer whose app is in the background.

## Stopping

Find `// TODO (Part 3): Stop advertising, stop scanning and drop the connections`
and replace it with:

```dart
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
```

## Listening for events

Everything so far was us doing things. Now we need to react to things.

Find `// TODO (Part 3): Wire up the peripheral role listeners` and replace it
with `_wirePeripheral();`, then find `// TODO (Part 3): Wire up the central role
listeners` and replace it with `_wireCentral();`.

Now add both methods. First the peripheral side, which is us being connected to:

```dart
  void _wirePeripheral() {
    _subs.add(
      _peripheral.stateChanged.listen((e) {
        _log(LogLevel.info, 'peripheral adapter ${e.state.name}');
      }),
    );

    // 1
    _subs.add(
      _peripheral.characteristicNotifyStateChanged.listen((e) async {
        if (e.characteristic.uuid != _txUuid) return;
        final key = '${e.central.uuid}';
        if (e.state) {
          _centrals[key] = e.central;
          // 2
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
        // 3
        try {
          await _peripheral.respondWriteRequest(e.request);
        } catch (err) {
          _log(LogLevel.error, 'respond failed: $err');
        }
        // 4
        if (e.characteristic.uuid != _rxUuid) return;
        _receive(e.request.value, 'write', '${e.central.uuid}');
      }),
    );
  }
```

In the above code:

1. A central subscribing to our TX is the moment we can actually talk to it, so
   this is where we start tracking it. Not when it connects. A connection we
   cannot notify on is useless to us.
2. Ask the connection how many bytes we can push in one notify, and remember it.
   This is that runtime number from Part 2 instead of a guess.
3. **Answer the write request first, before doing anything with the data.** An
   unanswered request blocks the sender's queue, and a blocked queue looks exactly
   like a dead link. I spent a while on that one.
4. Only then handle the payload, and only if it landed on the characteristic we
   care about.

Now the central side, which is us connecting out:

```dart
  void _wireCentral() {
    _subs.add(
      _central.stateChanged.listen((e) {
        _log(LogLevel.info, 'central adapter ${e.state.name}');
      }),
    );

    // 1
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

    // 2
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

    // 3
    _subs.add(
      _central.characteristicNotified.listen((e) {
        if (e.characteristic.uuid != _txUuid) return;
        _receive(e.value, 'notify', '${e.peripheral.uuid}');
      }),
    );
  }
```

In the above code:

1. Discovery fires repeatedly for the same phone, several times a second, so the
   `_dialling` set stops us from opening a new connection on every single
   advertisement.
2. Connecting is not the end of it. A connection gives us nothing until we have
   found the service and subscribed, which is the next method.
3. This is data arriving on a peer's TX, so a peer we dialled talking back to us.

## Setting up a connection

This is the longest piece, and it is everything that has to happen between
"connected" and "actually able to talk". Add it after `_wireCentral`:

```dart
  Future<void> _setUpOutbound(Peripheral peripheral) async {
    final key = '${peripheral.uuid}';
    try {
      // 1
      if (Platform.isAndroid) {
        try {
          final mtu = await _central.requestMTU(peripheral, mtu: 517);
          _log(LogLevel.info, 'negotiated mtu $mtu');
        } catch (err) {
          _log(LogLevel.warn, 'requestMTU: $err');
        }
      }

      // 2
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

      // 3
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

      // 4
      await _central.setCharacteristicNotifyState(peripheral, tx, state: true);

      // 5
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
```

In the above code:

1. Ask for a bigger MTU. Android only, because on iOS this throws and iOS
   negotiates on its own anyway. Wrapped in its own try so a failure here does not
   kill the rest of the setup.
2. Find our service on the peer. If it is not there, this is not one of our
   phones, so disconnect and move on.
3. Find the two characteristics inside it. Same idea.
4. Subscribe to the peer's TX. Without this the peer physically cannot send us
   anything, because a peripheral can only notify a central that subscribed.
5. Ask how many bytes we can write in one go, defaulting to the pessimistic 20 if
   the call fails. Only now do we record the link as usable.

Also add the `_short` helper, which we have been using in the logs:

```dart
  static String _short(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(uuid.length - 8);
```

That takes the **tail** of the uuid, not the front. Android builds a peer's uuid
out of its MAC address and pads the front with zeros, so the first eight
characters are all zeros and tell you nothing.

## Sending and receiving

Almost there. Find `// TODO (Part 3): Send to every connected peer` and replace it
with:

```dart
    final bytes = Uint8List.fromList(utf8.encode(text));
    _log(
      LogLevel.tx,
      'send ${bytes.length}B to ${_links.length + _notifyLimit.length} peer(s)',
    );

    // 1
    for (final link in _links.values.toList()) {
      if (bytes.length > link.maxWrite) {
        final peer = _short('${link.peripheral.uuid}');
        _log(LogLevel.warn, 'too long for $peer');
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
        _log(LogLevel.error, 'write failed: $e');
      }
    }

    // 2
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
```

In the above code:

1. To peers we dialled, we are the central, so we **write** to their RX.
2. To peers that dialled us, we are the peripheral, so we **notify** on our TX.

Two loops for two directions, exactly as Part 2 predicted. And both check the
length against that connection's own limit before sending, because the limit
differs per connection.

Finally, add the receive method:

```dart
  void _receive(Uint8List bytes, String via, String key) {
    final text = utf8.decode(bytes, allowMalformed: true);
    _log(LogLevel.rx, 'recv ${bytes.length}B via $via');
    if (_messages.isClosed) return;
    _messages.add(
      InboundMessage(text: text, peer: _short(key), via: via),
    );
  }
```

`allowMalformed: true` because bytes off a radio are not guaranteed to be valid
UTF-8, and a decode exception in a stream listener is a bad way to find that out.

## Run it

Install on two phones, switch Bluetooth on for both, and press Start on each.

Here is what my DuoQin F21 Pro logged, talking to an iPhone:

```
46:42.752  peripheral adapter poweredOn
46:48.335  advertising
46:48.355  scanning for 6f5d0001
46:50.663  dialling 2b057182 (rssi -49)
46:52.601  central 2b057182 subscribed, 512B
46:54.971  negotiated mtu 517
46:55.029  peer 2b057182 ready, 512B
```

Read that from the bottom up and both roles are there. `central 2b057182
subscribed` is the iPhone connecting to **us**. `peer 2b057182 ready` is us
connecting to **the iPhone**. Both at the same time, which is the whole point.

MTU negotiated to 517 with 512 bytes usable, and that is between an Android phone
and an iPhone. In Part 2 I said the common wisdom is that iOS caps around 185.
This is why you read the number at runtime instead of trusting the number in a
blog post, including this one.

Type something and hit send, and it appears on the other phone.

## The bug you just built

Now look at the receiving phone's log after one single message:

```
39:09.611  recv 14B via write
39:09.694  recv 14B via notify
```

Two bubbles in the chat. One message, delivered twice.

Nothing is broken. This is exactly what we told the code to do. When two phones
meet, **both** of them see the other advertising, and **both** dial. So you end up
with two connections between the same pair of phones, one in each direction. Our
`send()` loops over `_links` and over `_centrals`, and the same phone is sitting
in both, so it gets the message down both paths.

This is the problem I pointed at in Part 2 when I said there is no obvious right
answer. If both sides connect you get duplicates. If both sides politely wait, no
connection ever forms. You cannot just pick "the lower one" either, because at the
moment you connect you do not yet know **who** you are talking to. All you have is
a uuid that the operating system made up, and on iOS the same phone looks like a
completely different uuid to each observer.

So before we can fix the duplicate, the two phones need to tell each other who
they are. That is Part 6, and it turned out to be the most surprising part of this
whole project.

## Next up

Part 4 is short and it is about the thing that made everything after it possible:
making a BLE app you can actually debug. A blank grey screen that was really an
exception thrown from a getter, why you cannot trust release builds to show you
errors, and getting the logs off the phone and into your terminal.

It is not glamorous, but I did it out of order in the real project and regretted
it, so it goes here.

The finished code for this part is on the `part-03` branch. If something does not
work or I have explained something badly, [ping me](https://x.com/Anipy1).
