# elevator-clusterd

A headless, native-Swift **cluster-peer daemon** for the ElevatorSystem
macOS app. It simulates one or more OpenVMS-style dispatcher *nodes* — each
owning its own cluster of auto-driven cabs — and publishes them on the LAN
over the same Bonjour peer protocol the app speaks. Run it next to the app on
a single Mac and its cabs appear in the app as remote peers, so you can
**demonstrate the multi-peer networking without a second machine**.

It is **cross-platform** — builds and runs on **macOS, Linux, and Windows**.
On macOS it uses Bonjour/Network.framework; on Linux and Windows it uses a
hand-rolled mDNS + BSD-socket transport that speaks the identical wire, so a
daemon on a Linux box on your LAN is discovered by the macOS app exactly like
another Mac would be. Still zero external dependencies (Foundation only).

Un démon *headless* en Swift natif qui simule un ou plusieurs nœuds
régulateurs d'ascenseurs et les publie sur le réseau via le même protocole
Bonjour que l'application ElevatorSystem. Multi-plateforme (macOS, Linux,
Windows) : sur Linux/Windows, un moteur mDNS + sockets BSD écrit à la main
parle le même protocole que Bonjour. Permet de démontrer le fonctionnement
multi-pair sur une seule machine.

---

## Build & run

This is a **self-contained SwiftPM package** with no external dependencies —
separate from the app's XcodeGen build. Native `swift` mechanics only, on any
of the three platforms:

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
> each other. On macOS 14/15+ raw multicast is gated by the same control, so if
> a *forced-socket* run (below) "sees no peers", check that grant first.

---

## Platforms & transport

| Platform | Discovery + transport | Host metrics |
|----------|----------------------|--------------|
| **macOS** | Bonjour / Network.framework | full (Mach + IOKit): CPU, mem, page-fault & disk rates, processes |
| **Linux** | hand-rolled mDNS + BSD sockets | full (`/proc` + `statvfs`); no `lookups` counter so the lock-rate row reads 0 |
| **Windows** | hand-rolled mDNS + Winsock | CPU / mem / process-count / volumes real; page-fault, disk & lock **rates are documented light synthetic** (real ones need PDH/ETW) |

Both transports are **wire-identical** — newline-delimited JSON over TCP,
discovered via `_elevatorsys._tcp` on the LAN — so any mix of macOS app, macOS
daemon, Linux daemon, and Windows daemon interoperate on one mesh.

**Force the socket transport on macOS** (to exercise the Linux/Windows code path
against the real app) with a flag or env var:

```bash
swift run elevator-clusterd --socket           # or:
ELEVATORD_TRANSPORT=socket swift run elevator-clusterd
```

**Caveats.** The mDNS engine binds UDP `:5353` and joins `224.0.0.251`; make sure
the host firewall allows mDNS (Linux: open 5353/udp, e.g. `ufw allow 5353/udp`;
Windows: allow the binary through Defender Firewall for Private networks). Peers
must share an L2 broadcast domain (mDNS is link-local; it won't cross a router or
most VPNs). `--selftest` runs the wire codecs and exits — handy in CI.

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
| `ClusterNode.swift`  | Glues a simulator to a peer link; owns the sim/broadcast/stats timers, the transport factory, + `Logger`. |
| `main.swift`         | CLI parsing, transport selection, cross-platform signal/shutdown, run loop. |
| **Transport (shared)** | |
| `PeerSession.swift`  | Transport-agnostic handshake / dedup / broadcast over the `RawConn` + `PeerLink` protocols. |
| **Transport (Apple)** | |
| `ApplePeerLink.swift`| Bonjour listener + browser + `NWConnection` framing (was `PeerLink.swift`). `#if canImport(Network)`. |
| **Transport (Linux / Windows)** | |
| `SocketShim.swift`   | Cross-platform BSD-socket / Winsock primitives (handles, options, multicast, local-IP). |
| `DNSMessage.swift`   | Minimal DNS/mDNS wire codec (PTR/SRV/TXT/A, name compression) + self-test. |
| `MDNSEngine.swift`   | Process-wide mDNS responder + browser on one `:5353` socket, shared by all nodes. |
| `SocketPeerLink.swift`| Per-node TCP listener/dialer + writer/reader threads; drives `PeerSession`. |
| **Host metrics** | |
| `HostStats.swift`    | Façade: metric types, delta/rate/caching, `snapshot()`; calls per-OS primitives. |
| `HostStats+Darwin.swift` / `+Linux.swift` / `+FreeBSD.swift` / `+Windows.swift` | Per-OS raw sampling (Mach+IOKit / `/proc` / sysctl+getmntinfo / Win32). |
| `CHostStatsFreeBSD` (C target) | Tiny C shim re-exposing `sysctl(3)` for the FreeBSD sampler — the Swift `Glibc` overlay omits `<sys/sysctl.h>` there. Stubs on every other OS. |
| `CHostStatsWindows` (C target) | Tiny C shim re-exposing `EnumProcesses` / `GetProcessMemoryInfo` for the Windows sampler — the Swift `WinSDK` overlay omits those `<psapi.h>` calls. Stubs on every other OS. |

### Keeping in sync with the app

The wire types here are **hand-mirrored**, not cross-imported, so the daemon
stays free of the app's SwiftUI/SceneKit/AppKit dependencies. If you change
any of these in the app, update the mirror here to match:

- `Sources/ElevatorSystem/Networking/Protocol.swift` → `Wire.swift`
- `Sources/ElevatorSystem/Models/Elevator.swift` (esp. `CodingKeys`) → `Model.swift`
- `Sources/ElevatorSystem/Models/Constants.swift` (`enum Sim`) → `Model.swift`
- `Sources/ElevatorSystem/DCL/HostStats.swift` → `HostStats.swift` (+ the per-OS
  `HostStats+*.swift`); only the seven `HostSnapshot` fields cross the wire, but
  the sampling API mirrors the app's `HostStats` for parity.

The daemon's mDNS is a from-scratch implementation of just enough DNS-SD for the
app's `NWBrowser` to discover and resolve it; if the app's Bonjour service type,
TXT keys (`peerId`/`label`), or the "higher peerId dials" rule change in
`PeerNetwork.swift`, mirror them in `MDNSEngine.swift` / `SocketPeerLink.swift`.
The `Elevator` decoder tolerates missing newer fields (`decodeIfPresent`), so a
version skew degrades gracefully rather than dropping the peer.

---

## Scope

This is a **dispatch/visualization simulator**, like the app — not a safety
controller. It models normal automatic dispatch only; per-node concerns that
aren't carried on the peer protocol (SCADA alarms, Phase I/II fire modes, EPO,
hall-call allocation, destination dispatch) are intentionally left to the app.
