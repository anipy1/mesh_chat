# mesh chat

A BLE mesh messenger built from scratch in Flutter, one blog part at a time.

Messages hop from phone to phone over Bluetooth Low Energy, with no server, no
accounts and no internet. Two phones that cannot see each other can still talk,
as long as a third phone is somewhere in between.

## Branches

| branch | what is on it |
|---|---|
| `starter` | The UI, complete, with `// TODO` comments where the logic goes. Start here. |
| `part-03` | After Part 3: two phones exchanging bytes. |
| `main` | The finished thing: relay, flood damping, identity, the lot. |

Each part of the series has its own branch, so you can either follow along on
`starter` and write the code yourself, or check out the branch for a part and read
the finished version.

## Getting started

```shell
git clone -b starter --single-branch https://github.com/anipy1/mesh_chat
```

Open it, run `flutter pub get`, and launch it on a phone. At this point it is a
UI with nothing behind it. The Start button does nothing yet, which is what the
series is for.

## What you need

**Real phones. At least two, and three if you want to see a message hop.**
Emulators and simulators have no Bluetooth radio, so none of this can be tested on
a laptop.

Mixed platforms are better than matched ones. Two Android phones talking to each
other work far more smoothly than Android talking to iOS, and that smoothness
hides most of the interesting problems.

## Where the blog articles live

`blog/` holds the written parts. They teach the code on the `part-*` branches.

## The series

1. What this actually takes
2. GATT, roles, and why a mesh is different
3. First contact: two phones, one byte
4. When it fails silently: making a BLE app debuggable
5. Designing a wire format you can still change later
6. Who are you? Identity over a link
7. Becoming a mesh: relay and TTL
8. How do you even test a mesh?
9. Broadcast storms: why flooding needs brakes
10. Field guide to Android and iOS BLE differences
11. What is left, and in what order
