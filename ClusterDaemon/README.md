# elevator-clusterd

A headless, native-Swift **cluster-peer daemon** for the ElevatorSystem
macOS app. It simulates one or more OpenVMS-style dispatcher *nodes* — each
owning its own cluster of auto-driven cabs — and publishes them on the LAN
over the same Bonjour peer protocol the app speaks. Run it next to the app on
a single Mac and its cabs appear in the app as remote peers, so you can
**demonstrate the multi-peer networking without a second machine**.

Un **démon pair de cluster** *headless* en Swift natif pour l'application
macOS ElevatorSystem. Il simule un ou plusieurs *nœuds* régulateurs de style
OpenVMS — chacun possédant son propre cluster de cabines autonomes — et les
publie sur le réseau local via le même protocole pair Bonjour que
l'application. Lancez-le à côté de l'application sur un seul Mac : ses cabines
y apparaissent comme des pairs distants, ce qui permet de **démontrer le
réseau multi-pair sans seconde machine**.

English · [Français](#français)

---

## English

It is **cross-platform** — builds and runs on **macOS, Linux, and Windows**.
On macOS it uses Bonjour/Network.framework; on Linux and Windows it uses a
hand-rolled mDNS + BSD-socket transport that speaks the identical wire, so a
daemon on a Linux box on your LAN is discovered by the macOS app exactly like
another Mac would be. Still zero external dependencies (Foundation only).

### Build & run

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

#### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `-n, --nodes N`  | `1`        | Independent peer nodes to publish (each is a distinct Bonjour node). |
| `-c, --cabs N`   | `4`        | Cabs per node. |
| `-l, --label S`  | `SIMNODE`  | Node label / Bonjour name prefix (multi-node runs append `1`, `2`, …). |
| `-f, --floors N` | `10`       | Top floor cabs travel to (`2…10`; keep ≤ the app's floor count). |
| `-r, --rate N`   | `60`       | `.state` broadcasts per second (`1…60`). Default matches the 60 Hz sim tick. |
| `-q, --quiet`    | off        | Suppress per-event logging (banner + heartbeat only). |
| `-h, --help`     |            | Usage. |

#### Demo recipes

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

### Platforms & transport

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

### How it fits the app

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

#### Source layout

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

#### Keeping in sync with the app

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

### Scope

This is a **dispatch/visualization simulator**, like the app — not a safety
controller. It models normal automatic dispatch only; per-node concerns that
aren't carried on the peer protocol (SCADA alarms, Phase I/II fire modes, EPO,
hall-call allocation, destination dispatch) are intentionally left to the app.

---

## Français

Il est **multi-plateforme** — se compile et s'exécute sur **macOS, Linux et
Windows**. Sur macOS il utilise Bonjour/Network.framework ; sur Linux et
Windows il utilise un transport mDNS + sockets BSD écrit à la main qui parle
exactement la même trame, si bien qu'un démon tournant sur une machine Linux
de votre réseau local est découvert par l'application macOS exactement comme
le serait un autre Mac. Toujours zéro dépendance externe (Foundation
uniquement).

### Compilation et lancement

C'est un **paquet SwiftPM autonome** sans dépendance externe — distinct de la
build XcodeGen de l'application. Uniquement des mécanismes `swift` natifs, sur
chacune des trois plateformes :

```bash
cd ClusterDaemon
swift build            # ou : swift build -c release
swift run elevator-clusterd
```

Ou lancez directement le binaire compilé :

```bash
.build/debug/elevator-clusterd --nodes 3 --cabs 2
```

Vous pouvez aussi le piloter depuis la racine du dépôt sans `cd` :

```bash
swift run --package-path ClusterDaemon elevator-clusterd
```

#### Options

| Drapeau | Défaut | Signification |
|------|---------|---------|
| `-n, --nodes N`  | `1`        | Nœuds pairs indépendants à publier (chacun est un nœud Bonjour distinct). |
| `-c, --cabs N`   | `4`        | Cabines par nœud. |
| `-l, --label S`  | `SIMNODE`  | Étiquette de nœud / préfixe du nom Bonjour (les exécutions multi-nœuds ajoutent `1`, `2`, …). |
| `-f, --floors N` | `10`       | Étage le plus haut atteint par les cabines (`2…10` ; gardez-le ≤ au nombre d'étages de l'application). |
| `-r, --rate N`   | `60`       | Diffusions `.state` par seconde (`1…60`). Le défaut correspond au tick de simulation à 60 Hz. |
| `-q, --quiet`    | désactivé  | Supprime la journalisation par événement (bannière + *heartbeat* uniquement). |
| `-h, --help`     |            | Aide. |

#### Exemples de démonstration

```bash
# Un nœud régulateur supplémentaire avec un cluster de 4 cabines — la démo « ajouter des cabines » la plus simple.
swift run elevator-clusterd

# Un cluster de 3 nœuds (6 cabines). Le MONITOR CLUSTER de l'application liste alors le nœud
# local plus SIMNODE1/2/3 — un cluster complet depuis un seul Mac.
swift run elevator-clusterd --nodes 3 --cabs 2
```

Lancez ensuite l'application ElevatorSystem. En quelques secondes, les cabines
du démon apparaissent dans le **Régulateur de groupe** (étiquetées
`[REMOTE]`), s'animent dans la vue 3D **Synoptique de gaine**, et chaque nœud
apparaît dans **`MONITOR CLUSTER`** dans le terminal DCL avec des chiffres
CPU/mémoire en direct. `Ctrl-C` arrête le démon ; il envoie un `bye` pour que
l'application retire proprement les cabines.

> **Note au premier lancement :** macOS peut demander à votre terminal l'accès
> au réseau local (le démon utilise Bonjour/mDNS). Autorisez-le, sinon
> l'application et le démon ne se trouveront pas. Sur macOS 14/15+, le
> multicast brut est soumis au même contrôle ; donc si une exécution en
> *socket forcé* (ci-dessous) « ne voit aucun pair », vérifiez d'abord cette
> autorisation.

### Plateformes et transport

| Plateforme | Découverte + transport | Métriques hôte |
|----------|----------------------|--------------|
| **macOS** | Bonjour / Network.framework | complètes (Mach + IOKit) : CPU, mémoire, taux de défauts de page et de disque, processus |
| **Linux** | mDNS + sockets BSD faits main | complètes (`/proc` + `statvfs`) ; pas de compteur `lookups`, donc la ligne du taux de verrous affiche 0 |
| **Windows** | mDNS + Winsock faits main | CPU / mémoire / nombre de processus / volumes réels ; les **taux** de défauts de page, de disque et de verrous sont **une synthèse légère documentée** (les vrais nécessitent PDH/ETW) |

Les deux transports sont **identiques au bit près** — du JSON délimité par
saut de ligne sur TCP, découvert via `_elevatorsys._tcp` sur le réseau local —
de sorte que n'importe quel mélange d'application macOS, de démon macOS, de
démon Linux et de démon Windows interopère sur un même maillage.

**Forcez le transport socket sur macOS** (pour exercer le chemin de code
Linux/Windows face à la vraie application) avec un drapeau ou une variable
d'environnement :

```bash
swift run elevator-clusterd --socket           # ou :
ELEVATORD_TRANSPORT=socket swift run elevator-clusterd
```

**Mises en garde.** Le moteur mDNS se lie à l'UDP `:5353` et rejoint
`224.0.0.251` ; assurez-vous que le pare-feu de l'hôte autorise le mDNS
(Linux : ouvrez 5353/udp, p. ex. `ufw allow 5353/udp` ; Windows : autorisez le
binaire dans le pare-feu Defender pour les réseaux privés). Les pairs doivent
partager un même domaine de diffusion L2 (le mDNS est link-local ; il ne
traverse ni routeur ni la plupart des VPN). `--selftest` exécute les codecs de
trame puis quitte — pratique en CI.

### Comment il s'intègre à l'application

Le démon est compatible au niveau trame avec le protocole pair de
l'application — ce n'est qu'un nœud de plus sur le maillage, indiscernable
d'un second Mac exécutant l'application :

- **Découverte** — publie un service Bonjour `_elevatorsys._tcp` par nœud avec
  un enregistrement TXT `peerId`/`label`, et recherche les autres. Le pair au
  `peerId` le plus élevé initie la connexion, de sorte que chaque paire forme
  exactement un lien TCP.
- **Protocole** — des messages JSON délimités par saut de ligne `hello` /
  `state` / `stats` / `bye` (`Wire.swift`), identiques au bit près à
  `Sources/ElevatorSystem/Networking/Protocol.swift` de l'application.
- **Propriété** — chaque cabine porte le `peerId` du nœud ; l'application les
  affiche mais seul le démon les modifie (`canControl` reste false côté
  application).
- **Physique** — `CabSimulator.advance()` reproduit `ElevatorWorld.advance()`
  de l'application (machine à états des portes + mouvement trapézoïdal). La
  simulation tourne à 60 Hz et chaque nœud rediffuse l'état `.state` des
  cabines à `--rate` Hz (60 par défaut, correspondant au tick). À 60 Hz,
  l'application cale nos cabines de façon autoritaire à chacune de ses propres
  trames ; des taux plus bas s'appuient sur sa propre extrapolation à 60 Hz de
  nos cabines entre les instantanés (moins de trafic, un peu plus lâche). Le
  *heartbeat* affiche le taux d'émission mesuré.

#### Organisation des sources

| Fichier | Rôle |
|------|------|
| `Model.swift`        | Constantes `Sim` + `Elevator`/`CabProfile`/`DoorState`/`Direction` — miroir compatible trame du modèle de l'application. |
| `Wire.swift`         | `PeerOp`/`PeerMessage`/`HostSnapshot`/`WireCodec` — miroir du protocole pair de l'application. |
| `CabSimulator.swift` | Cluster de cabines par nœud : régulation automatique + physique portes/mouvement. |
| `ClusterNode.swift`  | Relie un simulateur à un lien pair ; possède les minuteurs de simulation/diffusion/stats, la fabrique de transport et le `Logger`. |
| `main.swift`         | Analyse de la CLI, sélection du transport, signaux/arrêt multi-plateformes, boucle d'exécution. |
| **Transport (partagé)** | |
| `PeerSession.swift`  | Établissement de liaison / déduplication / diffusion agnostiques du transport via les protocoles `RawConn` + `PeerLink`. |
| **Transport (Apple)** | |
| `ApplePeerLink.swift`| Écouteur + navigateur Bonjour + tramage `NWConnection` (anciennement `PeerLink.swift`). `#if canImport(Network)`. |
| **Transport (Linux / Windows)** | |
| `SocketShim.swift`   | Primitives multi-plateformes sockets BSD / Winsock (handles, options, multicast, IP locale). |
| `DNSMessage.swift`   | Codec de trame DNS/mDNS minimal (PTR/SRV/TXT/A, compression de noms) + auto-test. |
| `MDNSEngine.swift`   | Répondeur + navigateur mDNS à l'échelle du processus sur un unique socket `:5353`, partagé par tous les nœuds. |
| `SocketPeerLink.swift`| Écouteur/composeur TCP par nœud + threads d'écriture/lecture ; pilote `PeerSession`. |
| **Métriques hôte** | |
| `HostStats.swift`    | Façade : types de métriques, delta/taux/cache, `snapshot()` ; appelle les primitives propres à chaque OS. |
| `HostStats+Darwin.swift` / `+Linux.swift` / `+FreeBSD.swift` / `+Windows.swift` | Échantillonnage brut propre à chaque OS (Mach+IOKit / `/proc` / sysctl+getmntinfo / Win32). |
| `CHostStatsFreeBSD` (cible C) | Petit shim C réexposant `sysctl(3)` pour l'échantillonneur FreeBSD — l'overlay Swift `Glibc` y omet `<sys/sysctl.h>`. Stubs sur tout autre OS. |
| `CHostStatsWindows` (cible C) | Petit shim C réexposant `EnumProcesses` / `GetProcessMemoryInfo` pour l'échantillonneur Windows — l'overlay Swift `WinSDK` omet ces appels `<psapi.h>`. Stubs sur tout autre OS. |

#### Rester synchronisé avec l'application

Les types de trame ici sont **recopiés à la main**, non importés, afin que le
démon reste exempt des dépendances SwiftUI/SceneKit/AppKit de l'application. Si
vous modifiez l'un de ces éléments dans l'application, mettez à jour le miroir
ici pour qu'il corresponde :

- `Sources/ElevatorSystem/Networking/Protocol.swift` → `Wire.swift`
- `Sources/ElevatorSystem/Models/Elevator.swift` (surtout `CodingKeys`) → `Model.swift`
- `Sources/ElevatorSystem/Models/Constants.swift` (`enum Sim`) → `Model.swift`
- `Sources/ElevatorSystem/DCL/HostStats.swift` → `HostStats.swift` (+ les
  `HostStats+*.swift` propres à chaque OS) ; seuls les sept champs de
  `HostSnapshot` traversent la trame, mais l'API d'échantillonnage reflète le
  `HostStats` de l'application par souci de parité.

Le mDNS du démon est une implémentation partant de zéro, couvrant juste assez
de DNS-SD pour que le `NWBrowser` de l'application le découvre et le résolve ;
si le type de service Bonjour de l'application, les clés TXT (`peerId`/`label`)
ou la règle « le peerId le plus élevé compose » changent dans
`PeerNetwork.swift`, répercutez-les dans `MDNSEngine.swift` /
`SocketPeerLink.swift`. Le décodeur `Elevator` tolère l'absence de champs plus
récents (`decodeIfPresent`), de sorte qu'un décalage de version se dégrade
proprement au lieu d'abandonner le pair.

### Portée

C'est un **simulateur de régulation/visualisation**, comme l'application — pas
un contrôleur de sécurité. Il ne modélise que la régulation automatique
normale ; les aspects propres à chaque nœud qui ne transitent pas par le
protocole pair (alarmes SCADA, modes incendie Phase I/II, EPO, allocation des
appels paliers, régulation à destination) sont volontairement laissés à
l'application.
