//! Sync module — cross-node synchronization protocol for nullclaw.
//!
//! Provides shared types for huginn <-> muninn sync:
//!   - Schema-versioned delta envelopes (DeltaHeader)
//!   - Node identity and sequence tracking (NodeId, SequenceNum, SyncCursor)
//!   - Typed delta payloads (MemoryDelta, TaskDelta, EventDelta)
//!   - Top-level wire message (SyncMessage) with validation
//!   - Conflict resolution policies (full_precedence, last_writer_wins, etc.)
//!   - Federated handshake, heartbeat, and peer state management

pub const types = @import("types.zig");
pub const protocol = @import("protocol.zig");
pub const conflict = @import("conflict.zig");
pub const federation = @import("federation.zig");

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

// Re-export conflict resolution types
pub const ConflictRecord = conflict.ConflictRecord;
pub const ConflictOutcome = conflict.ConflictOutcome;
pub const ResolutionPolicy = conflict.ResolutionPolicy;
pub const Side = conflict.Side;
pub const resolve = conflict.resolve;
pub const resolveWith = conflict.resolveWith;

// Re-export federation types
pub const PeerState = federation.PeerState;
pub const HandshakeResult = federation.HandshakeResult;
pub const HandshakeRequest = federation.HandshakeRequest;
pub const HandshakeResponse = federation.HandshakeResponse;
pub const Heartbeat = federation.Heartbeat;
pub const HeartbeatConfig = federation.HeartbeatConfig;
pub const PeerInfo = federation.PeerInfo;
pub const checkVersionCompatibility = federation.checkVersionCompatibility;

test {
    _ = types;
    _ = protocol;
    _ = conflict;
    _ = federation;
}
