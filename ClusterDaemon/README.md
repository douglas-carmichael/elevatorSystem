# elevator-clusterd

A headless, native-Swift **cluster-peer daemon** for the ElevatorSystem
macOS app. It simulates one or more OpenVMS-style dispatcher *nodes* — each
owning its own cluster of auto-driven cabs — and publishes them on the LAN
over the same Bonjour peer protocol the app speaks. Run it next to the app on
a single Mac and its cabs appear in the app as remote peers, so you can
**demonstrate the multi-peer networking without a second machine**.

Un démon *headless* en Swift natif qui simule un ou plusieurs nœuds
régulateurs d'ascenseurs et les publie sur le réseau via le même protocole
Bonjour que l'application ElevatorSystem. Permet de démontrer le
fonctionnement multi-pair sur une seule machine.

---

## Build & run

This is a **self-contained SwiftPM package** with no external dependencies —
separate from the app's XcodeGen build. Native `swift` mechanics only:

```bash
cd ClusterDaemon
swift build            # or: swift build -c release
swift run elevator-clusterd
```

Or run the built binary directly:

```bash
.build/debug/elevator-clusterd --nodes 3 --cabs 2
```

You can also drive it from the repo root without `cd`:

```bash
swift run --package-path ClusterDaemon elevator-clusterd
```

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `-n, --nodes N`  | `1`        | Independent peer nodes to publish (each is a distinct Bonjour node). |
| `-c, --cabs N`   | `4`        | Cabs per node. |
| `-l, --label S`  | `SIMNODE`  | Node label / Bonjour name prefix (multi-node runs append `1`, `2`, …). |
| `-f, --floors N` | `10`       | Top floor cabs travel to (`2…10`; keep ≤ the app's floor count). |
| `-r, --rate N`   | `60`       | `.state` broadcasts per second (`1…60`). Default matches the 60 Hz sim tick. |
| `-q, --quiet`    | off        | Suppress per-event logging (banner + heartbeat only). |
| `-h, --help`     |            | Usage. |

### Demo recipes

```bash
# One extra dispatcher with a cluster of 4 cabs — simplest "add cabs" demo.
swift run elevator-clusterd

# A 3-node cluster (6 cabs). The app's MONITOR CLUSTER then lists the local
# node plus SIMNODE1/2/3 — a full cluster from one Mac.
swift run elevator-clusterd --nodes 3 --cabs 2
```

Then launch the ElevatorSystem app. Within a couple of seconds the daemon's
cabs show up in the **Group Dispatcher** (tagged `[REMOTE]`), animate in the
**Hoistway Synoptic** 3D view, and each node appears in **`MONITOR CLUSTER`**
in the DCL terminal with live CPU/memory numbers. `Ctrl-C` stops the daemon;
it sends a `bye` so the app drops the cabs cleanly.

> **First-run note:** macOS may prompt your terminal for Local Network access
> (the daemon uses Bonjour/mDNS). Allow it, or the app and daemon won't find
> each other.

---

## How it fits the app

The daemon is wire-compatible with the app's peer protocol — it is just
another node on the mesh, indistinguishable from a second Mac running the app:

- **Discovery** — publishes an `_elevatorsys._tcp` Bonjour service per node
  with a `peerId`/`label` TXT record, and browses for others. The peer with
  the higher `peerId` dials out, so each pair forms exactly one TCP link.
- **Protocol** — newline-delimited JSON `hello` / `state` / `stats` / `bye`
  messages (`Wire.swift`), byte-identical to the app's
  `Sources/ElevatorSystem/Networking/Protocol.swift`.
- **Ownership** — every cab carries the node's `peerId`; the app shows them
  but only the daemon mutates them (`canControl` stays false on the app side).
- **Physics** — `CabSimulator.advance()` mirrors the app's
  `ElevatorWorld.advance()` (door state machine + trapezoidal motion). The sim
  ticks at 60 Hz and each node re-broadcasts cab `.state` at `--rate` Hz
  (default 60, matching the tick). At 60 Hz the app snaps our cabs
  authoritatively on every one of its own frames; lower rates lean on the
  app's own 60 Hz extrapolation of our cabs between snapshots (less traffic,
  slightly looser). The heartbeat prints the measured outbound rate.

### Source layout

| File | Role |
|------|------|
| `Model.swift`        | `Sim` constants + `Elevator`/`CabProfile`/`DoorState`/`Direction` — wire-compatible mirror of the app model. |
| `Wire.swift`         | `PeerOp`/`PeerMessage`/`HostSnapshot`/`WireCodec` — mirror of the app peer protocol. |
| `CabSimulator.swift` | Per-node cab cluster: automatic dispatch + door/motion physics. |
| `PeerLink.swift`     | Bonjour listener + browser + framed connections (mirrors `PeerNetwork`). |
| `HostSampler.swift`  | Real CPU/memory sampling off the Mach host for the `.stats` messages. |
| `ClusterNode.swift`  | Glues a simulator to a peer link; owns the sim/broadcast/stats timers. + `Logger`. |
| `main.swift`         | CLI parsing, signal handling, run loop. |

### Keeping in sync with the app

The wire types here are **hand-mirrored**, not cross-imported, so the daemon
stays free of the app's SwiftUI/SceneKit/AppKit dependencies. If you change
any of these in the app, update the mirror here to match:

- `Sources/ElevatorSystem/Networking/Protocol.swift` → `Wire.swift`
- `Sources/ElevatorSystem/Models/Elevator.swift` (esp. `CodingKeys`) → `Model.swift`
- `Sources/ElevatorSystem/Models/Constants.swift` (`enum Sim`) → `Model.swift`
- `HostStats.HostSnapshot` fields → `HostSnapshot` in `Wire.swift`

The `Elevator` decoder tolerates missing newer fields (`decodeIfPresent`), so
a version skew degrades gracefully rather than dropping the peer.

---

## Scope

This is a **dispatch/visualization simulator**, like the app — not a safety
controller. It models normal automatic dispatch only; per-node concerns that
aren't carried on the peer protocol (SCADA alarms, Phase I/II fire modes, EPO,
hall-call allocation, destination dispatch) are intentionally left to the app.
