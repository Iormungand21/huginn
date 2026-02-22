//! Sync module — cross-node synchronization protocol for nullclaw.
//!
//! Provides shared types for huginn <-> muninn sync:
//!   - Schema-versioned delta envelopes (DeltaHeader)
//!   - Node identity and sequence tracking (NodeId, SequenceNum, SyncCursor)
//!   - Typed delta payloads (MemoryDelta, TaskDelta, EventDelta)
//!   - Top-level wire message (SyncMessage) with validation
//!
//! Transport and conflict resolution are deferred to later sync stages.

pub const types = @import("types.zig");
pub const protocol = @import("protocol.zig");

// Re-export core types for convenient access
pub const SCHEMA_VERSION = types.SCHEMA_VERSION;
pub const PROTOCOL_MAGIC = types.PROTOCOL_MAGIC;
pub const NodeId = types.NodeId;
pub const SequenceNum = types.SequenceNum;
pub const INITIAL_SEQUENCE = types.INITIAL_SEQUENCE;
pub const Timestamp = types.Timestamp;
pub const DeltaKind = types.DeltaKind;
pub const DeltaOp = types.DeltaOp;
pub const DeltaHeader = types.DeltaHeader;
pub const SyncCursor = types.SyncCursor;

// Re-export protocol payloads
pub const MemoryDelta = protocol.MemoryDelta;
pub const TaskDelta = protocol.TaskDelta;
pub const EventDelta = protocol.EventDelta;
pub const SyncMessage = protocol.SyncMessage;
pub const memoryMessage = protocol.memoryMessage;
pub const taskMessage = protocol.taskMessage;
pub const eventMessage = protocol.eventMessage;

test {
    _ = types;
    _ = protocol;
}
