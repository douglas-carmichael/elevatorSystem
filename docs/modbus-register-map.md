# Modbus TCP register map — lab reference (GEII)

The simulator exposes every cab and the building over **Modbus TCP** on
`127.0.0.1:5020` (loopback only). Any PLC/HMI/SCADA tool can read cab telemetry
and drive cars over the wire, exactly as it would talk to a real elevator
controller's gateway: `mbpoll`, `pymodbus`, **OpenPLC**, **Node-RED**,
FactoryIO, QModMaster, Modbus Poll, …

- Port **5020** (not 502) so no root is needed to bind. Every tool takes
  `-p 5020`.
- Addresses are **0-indexed**. Cab index follows the Group Dispatcher sort order
  (locally-owned cabs first, then remote peers). Up to **16 cabs** (`N = 16`).
- The unit-id / slave-address field is accepted and echoed regardless of value
  (the device is addressed by IP), so masters defaulting to 1, 128 or 255 work.
- Function codes: FC 01/02/03/04/05/06/0F/10.

The four Modbus tables map onto the four things a controller cares about:

| Table | FC | Meaning here |
|---|---|---|
| Coils | 01 / 05 / 0F | **Commands** (pulse-on) |
| Discrete inputs | 02 | **Status + safety chain** (read-only bits) |
| Holding registers | 03 / 06 / 10 | **Setpoints** (R/W) |
| Input registers | 04 | **Telemetry / status words** (read-only) |

`SHOW MODBUS` in the DCL terminal prints this same map live, with the
safety-chain contact names in the currently selected standard (see
`SET STANDARD`).

## Coils — commands (FC 01 read, 05/0F write)

Writing `ON` (0xFF00) issues the command; it is routed to the owning node for a
remote cab, exactly like the on-screen buttons.

| Address | Command |
|---|---|
| `0 … N-1` | Door **OPEN** |
| `N … 2N-1` | Door **CLOSE** |
| `2N … 3N-1` | **STOP** / cancel queue |

## Discrete inputs — status + chaîne de sécurité (FC 02)

Status bits:

| Address | Bit |
|---|---|
| `0 … N-1` | Cab is locally owned |
| `N … 2N-1` | Cab moving |
| `2N … 3N-1` | Doors open |
| `3N … 4N-1` | Holding brake engaged |
| `4N … 5N-1` | Door light-curtain obstructed |
| `5N … 6N-1` | Platform overload (> 110 % rated) |

**Safety chain** — series loop, **`1` = contact closed / healthy** (the way a
PLC reads a real chaîne de sécurité). Derived from cab telemetry, so remote
(daemon) cabs report a faithful chain too:

| Address | Contact (ASME / EN 81) |
|---|---|
| `6N … 7N-1` (96–111) | Door interlock locked |
| `7N … 8N-1` (112–127) | Terminal / **final** limit OK |
| `8N … 9N-1` (128–143) | Overspeed governor / **limiteur** OK |
| `9N … 10N-1` (144–159) | Car safety / **parachute** not tripped |
| `10N … 11N-1` (160–175) | Holding brake proven |
| `11N … 12N-1` (176–191) | **Safety chain intact** (AND of all + building normal) |

## Holding registers — setpoints (FC 03 read, 06/10 write)

| Address | Setpoint |
|---|---|
| `0 … N-1` | Profile (0 = PAX, 1 = Freight) |
| `N … 2N-1` | Mode (0 = Manual, 1 = Auto) |
| `2N … 3N-1` | **Target floor** — write to enqueue a CALL |

## Input registers — telemetry & status (FC 04)

Per-cab (`N = 16`):

| Address | Value |
|---|---|
| `0 … N-1` | Position × 10 (floor 3.5 → 35) |
| `N … 2N-1` | Direction (0 = idle, 1 = up, 2 = down) |
| `2N … 3N-1` | Door state (0 = closed, 1 = opening, 2 = open, 3 = closing) |
| `3N … 4N-1` | Queue depth |
| `4N … 5N-1` | Door progress (0–100 %) |
| `5N … 6N-1` | Velocity × 100 (signed Int16) |
| `6N … 7N-1` | Platform load (kg) |
| `7N … 8N-1` (112–127) | Acceleration × 100 (signed Int16, floors/s²) |

Building-wide scalars (base `1000`):

| Address | Value |
|---|---|
| 1000 | Cabs registered |
| 1001 | Remote peers connected |
| 1002 | Top floor |
| 1003 | Telnet sessions |
| 1004 | Modbus clients connected |
| 1005 | Building safety mode (0 = normal, 1 = fire, 2 = EPO) |
| 1006 | Recall floor |
| 1007 | Active SCADA alarms (**excludes shelved**) |
| 1008 | Highest active severity (0 none … 4 critical) |
| 1009 | Dispatch mode (0 = collective, 1 = destination) |
| 1010 | Active hall calls |
| 1011 | Unacknowledged alarms (ISA-18.2 UNACK) |
| 1012 | Shelved alarms (ISA-18.2 SHLVD) |
| 1013 | Returned-to-normal, unacknowledged (ISA-18.2 RTN) |

## Example lab invocations

Read cab 0's position, direction, door state (IR 0, 16, 32):

```bash
mbpoll -m tcp -p 5020 -t 4 -r 1 -c 1 127.0.0.1        # IR 0  (position ×10)
mbpoll -m tcp -p 5020 -t 4 -r 17 -c 1 127.0.0.1       # IR 16 (direction)
```

Send cab 0 to floor 5 (HR 32, one-based `-r 33`):

```bash
mbpoll -m tcp -p 5020 -t 4 -r 33 127.0.0.1 5          # write target floor
```

Watch the safety chain of cab 0 (DI 96–101, one-based `-r 97`):

```bash
mbpoll -m tcp -p 5020 -t 1 -r 97 -c 6 127.0.0.1       # 6 safety contacts
```

pymodbus (Python):

```python
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient("127.0.0.1", port=5020)
c.connect()
pos = c.read_input_registers(0, count=1).registers[0] / 10.0   # cab 0 floor
chain = c.read_discrete_inputs(176, count=1).bits[0]           # cab 0 chain intact
c.write_register(32, 5)                                        # cab 0 -> floor 5
```

> `mbpoll` addresses are **one-based** on the command line (`-r`), so add 1 to
> the 0-based addresses above; `pymodbus` uses the 0-based address directly.
