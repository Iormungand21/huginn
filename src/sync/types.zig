//! Shared sync protocol types and schema versioning for huginn <-> muninn.
//!
//! Defines the core primitives for cross-node synchronization:
//!   - Schema version for forward-compatible wire format evolution
//!   - NodeId for identifying sync participants
//!   - Sequence numbers for causal ordering
//!   - Timestamps for wall-clock reference
//!   - DeltaKind for classifying payload types (event, task, memory)

const std = @import("std");

// ── Schema version ─────────────────────────────────────────────────

/// Protocol schema version. Increment on breaking wire-format changes.
/// Receivers must reject messages with an unsupported schema version.
pub const SCHEMA_VERSION: u32 = 1;

/// Protocol identifier for quick format validation.
pub const PROTOCOL_MAGIC = "nullclaw-sync-v1";

// ── Node identity ──────────────────────────────────────────────────

/// Maximum length for a node identifier string.
pub const MAX_NODE_ID_LEN: usize = 64;

/// Identifies a participant in the sync protocol.
/// Typically a hostname, device name, or UUID — opaque to the protocol.
pub const NodeId = struct {
    /// Node identifier string (e.g. "huginn-pi5", "muninn-desktop").
    id: []const u8,

    pub fn eql(a: NodeId, b: NodeId) bool {
        return std.mem.eql(u8, a.id, b.id);
    }

    pub fn validate(self: NodeId) bool {
        return self.id.len > 0 and self.id.len <= MAX_NODE_ID_LEN;
    }
};

// ── Sequence numbers ───────────────────────────────────────────────

/// Monotonically increasing sequence number per node.
/// Each node maintains its own counter; receivers track the last-seen
/// sequence per source node to detect gaps or duplicates.
pub const SequenceNum = u64;

/// Starting sequence for a fresh node.
pub const INITIAL_SEQUENCE: SequenceNum = 1;

// ── Timestamps ─────────────────────────────────────────────────────

/// Wall-clock milliseconds since Unix epoch (UTC).
/// Used for human-readable ordering and TTL, not causal ordering
/// (use SequenceNum for that).
pub const Timestamp = i64;

// ── Delta kind ─────────────────────────────────────────────────────

/// Classification of a sync delta payload.
pub const DeltaKind = enum {
    /// A memory record was created, updated, or deleted.
    memory,
    /// A task state transition occurred.
    task,
    /// A timeline event was emitted.
    event,

    pub fn toString(self: DeltaKind) []const u8 {
        return switch (self) {
            .memory => "memory",
            .task => "task",
            .event => "event",
        };
    }

    pub fn fromString(s: []const u8) ?DeltaKind {
        if (std.mem.eql(u8, s, "memory")) return .memory;
        if (std.mem.eql(u8, s, "task")) return .task;
        if (std.mem.eql(u8, s, "event")) return .event;
        return null;
    }
};

// ── Delta operation ────────────────────────────────────────────────

/// What happened to the record.
pub const DeltaOp = enum {
    /// A new record was created.
    create,
    /// An existing record was modified.
    update,
    /// A record was removed.
    delete,

    pub fn toString(self: DeltaOp) []const u8 {
        return switch (self) {
            .create => "create",
            .update => "update",
            .delete => "delete",
        };
    }

    pub fn fromString(s: []const u8) ?DeltaOp {
        if (std.mem.eql(u8, s, "create")) return .create;
        if (std.mem.eql(u8, s, "update")) return .update;
        if (std.mem.eql(u8, s, "delete")) return .delete;
        return null;
    }
};

// ── Delta header ───────────────────────────────────────────────────

/// Common envelope carried by every sync delta, regardless of payload kind.
pub const DeltaHeader = struct {
    /// Protocol schema version.
    schema_version: u32 = SCHEMA_VERSION,
    /// Node that originated this delta.
    source_node: NodeId,
    /// Monotonic sequence number from the source node.
    sequence: SequenceNum,
    /// Wall-clock timestamp (ms since epoch) when the delta was created.
    timestamp: Timestamp,
    /// What kind of payload this delta carries.
    kind: DeltaKind,
    /// What operation this delta represents.
    op: DeltaOp,
    /// Opaque record identifier (unique within the source node).
    record_id: []const u8,
};

// ── Sync cursor ────────────────────────────────────────────────────

/// Tracks sync progress between two nodes.
/// The receiver stores one cursor per source node.
pub const SyncCursor = struct {
    /// The remote node this cursor tracks.
    remote_node: NodeId,
    /// Last sequence number successfully applied from that node.
    last_sequence: SequenceNum = 0,
    /// Wall-clock time of last successful sync (ms since epoch).
    last_sync_ts: Timestamp = 0,
};

// ── Tests ──────────────────────────────────────────────────────────

test "SCHEMA_VERSION is 1" {
    try std.testing.expectEqual(@as(u32, 1), SCHEMA_VERSION);
}

test "PROTOCOL_MAGIC is correct" {
    try std.testing.expectEqualStrings("nullclaw-sync-v1", PROTOCOL_MAGIC);
}

test "NodeId equality" {
    const a = NodeId{ .id = "huginn-pi5" };
    const b = NodeId{ .id = "huginn-pi5" };
    const c = NodeId{ .id = "muninn-desktop" };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "NodeId validate" {
    const valid = NodeId{ .id = "pi5" };
    try std.testing.expect(valid.validate());

    const empty = NodeId{ .id = "" };
    try std.testing.expect(!empty.validate());

    // 64 chars is OK
    const max_len = NodeId{ .id = "a" ** MAX_NODE_ID_LEN };
    try std.testing.expect(max_len.validate());

    // 65 chars is too long
    const too_long = NodeId{ .id = "a" ** (MAX_NODE_ID_LEN + 1) };
    try std.testing.expect(!too_long.validate());
}

test "INITIAL_SEQUENCE is 1" {
    try std.testing.expectEqual(@as(SequenceNum, 1), INITIAL_SEQUENCE);
}

test "DeltaKind toString roundtrip" {
    try std.testing.expectEqualStrings("memory", DeltaKind.memory.toString());
    try std.testing.expectEqualStrings("task", DeltaKind.task.toString());
    try std.testing.expectEqualStrings("event", DeltaKind.event.toString());
}

test "DeltaKind fromString valid" {
    try std.testing.expect(DeltaKind.fromString("memory").? == .memory);
    try std.testing.expect(DeltaKind.fromString("task").? == .task);
    try std.testing.expect(DeltaKind.fromString("event").? == .event);
}

test "DeltaKind fromString invalid returns null" {
    try std.testing.expect(DeltaKind.fromString("bogus") == null);
    try std.testing.expect(DeltaKind.fromString("") == null);
}

test "DeltaOp toString roundtrip" {
    try std.testing.expectEqualStrings("create", DeltaOp.create.toString());
    try std.testing.expectEqualStrings("update", DeltaOp.update.toString());
    try std.testing.expectEqualStrings("delete", DeltaOp.delete.toString());
}

test "DeltaOp fromString valid" {
    try std.testing.expect(DeltaOp.fromString("create").? == .create);
    try std.testing.expect(DeltaOp.fromString("update").? == .update);
    try std.testing.expect(DeltaOp.fromString("delete").? == .delete);
}

test "DeltaOp fromString invalid returns null" {
    try std.testing.expect(DeltaOp.fromString("bogus") == null);
    try std.testing.expect(DeltaOp.fromString("") == null);
}

test "DeltaHeader defaults" {
    const header = DeltaHeader{
        .source_node = .{ .id = "test-node" },
        .sequence = 42,
        .timestamp = 1700000000000,
        .kind = .memory,
        .op = .create,
        .record_id = "rec-001",
    };
    try std.testing.expectEqual(@as(u32, 1), header.schema_version);
    try std.testing.expectEqualStrings("test-node", header.source_node.id);
    try std.testing.expectEqual(@as(SequenceNum, 42), header.sequence);
    try std.testing.expect(header.kind == .memory);
    try std.testing.expect(header.op == .create);
    try std.testing.expectEqualStrings("rec-001", header.record_id);
}

test "SyncCursor defaults" {
    const cursor = SyncCursor{
        .remote_node = .{ .id = "remote" },
    };
    try std.testing.expectEqual(@as(SequenceNum, 0), cursor.last_sequence);
    try std.testing.expectEqual(@as(Timestamp, 0), cursor.last_sync_ts);
    try std.testing.expectEqualStrings("remote", cursor.remote_node.id);
}

test "SyncCursor with progress" {
    const cursor = SyncCursor{
        .remote_node = .{ .id = "muninn" },
        .last_sequence = 99,
        .last_sync_ts = 1700000000000,
    };
    try std.testing.expectEqual(@as(SequenceNum, 99), cursor.last_sequence);
    try std.testing.expectEqual(@as(Timestamp, 1700000000000), cursor.last_sync_ts);
}
