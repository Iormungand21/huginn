# Sync Protocol — huginn <-> muninn

Cross-node synchronization protocol for nullclaw instances.

## Overview

The sync protocol enables huginn and muninn nodes to exchange deltas — incremental changes to memory records, task states, and timeline events. Each delta carries a versioned envelope (header) and a typed payload body.

## Schema Versioning

- **Current version:** `1`
- **Protocol magic:** `nullclaw-sync-v1`
- Receivers **must reject** messages with an unsupported schema version.
- Bump `SCHEMA_VERSION` in `src/sync/types.zig` on breaking wire-format changes.

## Node Identity

Each participant is identified by a `NodeId` — an opaque string (max 64 chars) such as `"huginn-pi5"` or `"muninn-desktop"`.

## Causal Ordering

- Each node maintains a monotonically increasing `SequenceNum` (u64).
- Receivers track the last-seen sequence per source node via `SyncCursor` to detect gaps or duplicates.
- Wall-clock `Timestamp` (ms since epoch) is carried for human-readable reference but is **not** used for causal ordering.

## Delta Envelope (DeltaHeader)

Every sync message carries a common header:

| Field            | Type         | Description                                  |
|------------------|--------------|----------------------------------------------|
| `schema_version` | `u32`        | Protocol schema version                      |
| `source_node`    | `NodeId`     | Originating node                             |
| `sequence`       | `SequenceNum`| Monotonic per-node sequence                  |
| `timestamp`      | `Timestamp`  | Wall-clock ms since epoch                    |
| `kind`           | `DeltaKind`  | Payload type: `memory`, `task`, or `event`   |
| `op`             | `DeltaOp`    | Operation: `create`, `update`, or `delete`   |
| `record_id`      | `[]const u8` | Opaque record identifier (unique per node)   |

## Delta Payloads

### MemoryDelta

Changes to memory records (facts, preferences, episodes).

| Field        | Type          | Description                        |
|--------------|---------------|------------------------------------|
| `key`        | `[]const u8`  | Memory record key/title            |
| `content`    | `?[]const u8` | Content body (null on delete)      |
| `category`   | `?[]const u8` | core, daily, conversation, custom  |
| `kind`       | `?[]const u8` | semantic, episodic, procedural     |
| `tier`       | `?[]const u8` | pinned, standard, ephemeral        |
| `confidence` | `?f64`        | Score in [0, 1]                    |

### TaskDelta

Task state transitions.

| Field      | Type          | Description                              |
|------------|---------------|------------------------------------------|
| `task_id`  | `[]const u8`  | Task identifier                          |
| `status`   | `?[]const u8` | pending, running, completed, failed, ... |
| `title`    | `?[]const u8` | Task title/summary                       |
| `priority` | `?[]const u8` | low, normal, high, critical              |
| `notes`    | `?[]const u8` | Free-form notes                          |

### EventDelta

Timeline event emissions.

| Field        | Type          | Description                          |
|--------------|---------------|--------------------------------------|
| `event_id`   | `[]const u8`  | Event identifier                     |
| `severity`   | `?[]const u8` | debug, info, warn, error             |
| `event_kind` | `?[]const u8` | Classifier (e.g. "tool_call")        |
| `summary`    | `?[]const u8` | Human-readable summary               |
| `data_json`  | `?[]const u8` | Structured data as JSON string       |

## SyncMessage Validation

A `SyncMessage` is valid when:
1. `schema_version` matches the current `SCHEMA_VERSION`
2. `source_node` is non-empty and within length limits
3. Exactly one payload (`memory`, `task`, or `event`) is set
4. The payload kind matches `header.kind`

## Federation: Handshake and Heartbeat (X3-SYNC-001)

### Peer Connection Lifecycle (PeerState)

Peers progress through a strict state machine:

```
disconnected ──> handshake_pending ──> connected ──> degraded ──> offline
      ^               │                    │            │           │
      │               │ (rejected/         │ (clean     │ (clean    │
      └───────────────┘  timeout)          │  shutdown) │  shutdown)│
      ^                                    │            │           │
      └────────────────────────────────────┘────────────┘───────────┘
                                           │            │
                                           └────────────┘
                                         (heartbeat recovered)
```

| State               | Description                                         |
|---------------------|-----------------------------------------------------|
| `disconnected`      | No connection. Initial and reset state.             |
| `handshake_pending` | Handshake request sent, awaiting response.          |
| `connected`         | Handshake complete, heartbeats flowing normally.    |
| `degraded`          | Heartbeat(s) missed, not yet timed out.             |
| `offline`           | Peer unreachable (exceeded heartbeat timeout).      |

### Handshake Flow

1. **Initiator** sends `HandshakeRequest` with its `NodeId`, `schema_version`, and `last_seen_sequence`.
2. **Responder** checks version compatibility and sends `HandshakeResponse` with a `HandshakeResult`:
   - `accepted` — versions match, peer is allowed.
   - `rejected` — peer declined (policy, unknown node). Includes `reason`.
   - `version_mismatch` — incompatible schema versions.
3. On `accepted`, both peers transition to `connected` and begin heartbeat exchange.

| Field (Request)      | Type           | Description                          |
|----------------------|----------------|--------------------------------------|
| `source_node`        | `NodeId`       | Initiating node                      |
| `schema_version`     | `u32`          | Protocol version                     |
| `timestamp`          | `Timestamp`    | Request creation time                |
| `last_seen_sequence` | `SequenceNum`  | Last sequence seen from target (0=first contact) |

| Field (Response)     | Type              | Description                       |
|----------------------|-------------------|-----------------------------------|
| `source_node`        | `NodeId`          | Responding node                   |
| `schema_version`     | `u32`             | Protocol version                  |
| `timestamp`          | `Timestamp`       | Response creation time            |
| `result`             | `HandshakeResult` | accepted/rejected/version_mismatch|
| `reason`             | `?[]const u8`     | Human-readable rejection reason   |
| `last_seen_sequence` | `SequenceNum`     | Last sequence seen from initiator |

### Heartbeat Protocol

Connected peers exchange periodic `Heartbeat` messages to maintain liveness detection.

| Field         | Type           | Description                              |
|---------------|----------------|------------------------------------------|
| `source_node` | `NodeId`       | Sending node                             |
| `timestamp`   | `Timestamp`    | Heartbeat send time                      |
| `sequence`    | `SequenceNum`  | Current sequence at sender               |
| `uptime_ms`   | `u64`          | Node uptime in milliseconds              |

**HeartbeatConfig** controls timing thresholds:

| Field                  | Default  | Description                              |
|------------------------|----------|------------------------------------------|
| `interval_ms`          | 30,000   | Heartbeat send interval                  |
| `degraded_after_missed`| 2        | Missed heartbeats before degraded state  |
| `offline_after_missed` | 5        | Missed heartbeats before offline state   |

### PeerInfo Tracking

Each node maintains a `PeerInfo` record per known peer, tracking:
- Current `PeerState` with enforced valid transitions
- Last heartbeat timestamp and missed heartbeat count
- Connection establishment timestamp
- Last received sequence number (for gap detection)

Recovery: receiving a heartbeat while in `degraded` state automatically returns to `connected`.

## Future Work

- Wire encoding format selection (JSON, CBOR, or custom binary)
- Transport layer implementation (TCP, Unix socket, or mDNS discovery)
- Batched delta messages for bulk sync
- Compression for large payloads
- Peer discovery and automatic reconnection
