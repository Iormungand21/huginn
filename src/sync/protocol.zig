//! Sync protocol delta payloads for huginn <-> muninn.
//!
//! Defines the typed payload bodies carried inside a `DeltaHeader` envelope:
//!   - MemoryDelta  — memory record create/update/delete
//!   - TaskDelta    — task state transitions
//!   - EventDelta   — timeline event emissions
//!   - SyncMessage  — top-level wire message combining header + payload
//!
//! All payloads are serialization-ready scaffolds. Wire encoding (JSON, CBOR,
//! etc.) and transport will be added in later sync stages.

const std = @import("std");
const types = @import("types.zig");

const DeltaHeader = types.DeltaHeader;
const DeltaKind = types.DeltaKind;
const DeltaOp = types.DeltaOp;
const NodeId = types.NodeId;
const SequenceNum = types.SequenceNum;
const Timestamp = types.Timestamp;
const SCHEMA_VERSION = types.SCHEMA_VERSION;

// ── Memory delta ───────────────────────────────────────────────────

/// Payload for a memory record change.
pub const MemoryDelta = struct {
    /// Memory record key/title.
    key: []const u8,
    /// Content body (null on delete).
    content: ?[]const u8 = null,
    /// Memory category (core, daily, conversation, custom).
    category: ?[]const u8 = null,
    /// Semantic kind (semantic, episodic, procedural).
    kind: ?[]const u8 = null,
    /// Retention tier (pinned, standard, ephemeral).
    tier: ?[]const u8 = null,
    /// Confidence score in [0, 1].
    confidence: ?f64 = null,
};

// ── Task delta ─────────────────────────────────────────────────────

/// Payload for a task state transition.
pub const TaskDelta = struct {
    /// Task identifier.
    task_id: []const u8,
    /// New status (pending, running, completed, failed, cancelled, blocked).
    status: ?[]const u8 = null,
    /// Task title/summary.
    title: ?[]const u8 = null,
    /// Priority level (low, normal, high, critical).
    priority: ?[]const u8 = null,
    /// Free-form notes or status message.
    notes: ?[]const u8 = null,
};

// ── Event delta ────────────────────────────────────────────────────

/// Payload for a timeline event emission.
pub const EventDelta = struct {
    /// Event identifier.
    event_id: []const u8,
    /// Event severity (debug, info, warn, error).
    severity: ?[]const u8 = null,
    /// Event kind classifier (e.g. "tool_call", "agent_step").
    event_kind: ?[]const u8 = null,
    /// Human-readable summary.
    summary: ?[]const u8 = null,
    /// Optional structured data as JSON string.
    data_json: ?[]const u8 = null,
};

// ── Sync message ───────────────────────────────────────────────────

/// Top-level wire message: header envelope + typed payload.
pub const SyncMessage = struct {
    /// Common delta header (version, source, sequence, timestamp, kind, op).
    header: DeltaHeader,
    /// Payload body — exactly one is non-null, matching header.kind.
    memory: ?MemoryDelta = null,
    task: ?TaskDelta = null,
    event: ?EventDelta = null,

    /// Validate that exactly one payload is set and matches the header kind.
    pub fn validate(self: SyncMessage) bool {
        if (self.header.schema_version != SCHEMA_VERSION) return false;
        if (!self.header.source_node.validate()) return false;

        const has_memory = self.memory != null;
        const has_task = self.task != null;
        const has_event = self.event != null;

        // Exactly one payload must be present
        const count = @as(u8, @intFromBool(has_memory)) +
            @as(u8, @intFromBool(has_task)) +
            @as(u8, @intFromBool(has_event));
        if (count != 1) return false;

        // Payload must match header kind
        return switch (self.header.kind) {
            .memory => has_memory,
            .task => has_task,
            .event => has_event,
        };
    }
};

// ── Convenience constructors ───────────────────────────────────────

/// Build a SyncMessage for a memory delta.
pub fn memoryMessage(
    source: NodeId,
    seq: SequenceNum,
    ts: Timestamp,
    op: DeltaOp,
    record_id: []const u8,
    payload: MemoryDelta,
) SyncMessage {
    return .{
        .header = .{
            .source_node = source,
            .sequence = seq,
            .timestamp = ts,
            .kind = .memory,
            .op = op,
            .record_id = record_id,
        },
        .memory = payload,
    };
}

/// Build a SyncMessage for a task delta.
pub fn taskMessage(
    source: NodeId,
    seq: SequenceNum,
    ts: Timestamp,
    op: DeltaOp,
    record_id: []const u8,
    payload: TaskDelta,
) SyncMessage {
    return .{
        .header = .{
            .source_node = source,
            .sequence = seq,
            .timestamp = ts,
            .kind = .task,
            .op = op,
            .record_id = record_id,
        },
        .task = payload,
    };
}

/// Build a SyncMessage for an event delta.
pub fn eventMessage(
    source: NodeId,
    seq: SequenceNum,
    ts: Timestamp,
    op: DeltaOp,
    record_id: []const u8,
    payload: EventDelta,
) SyncMessage {
    return .{
        .header = .{
            .source_node = source,
            .sequence = seq,
            .timestamp = ts,
            .kind = .event,
            .op = op,
            .record_id = record_id,
        },
        .event = payload,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "MemoryDelta defaults" {
    const delta = MemoryDelta{ .key = "fact-1" };
    try std.testing.expectEqualStrings("fact-1", delta.key);
    try std.testing.expect(delta.content == null);
    try std.testing.expect(delta.category == null);
    try std.testing.expect(delta.kind == null);
    try std.testing.expect(delta.tier == null);
    try std.testing.expect(delta.confidence == null);
}

test "MemoryDelta with all fields" {
    const delta = MemoryDelta{
        .key = "pref-dark-mode",
        .content = "user prefers dark mode",
        .category = "core",
        .kind = "semantic",
        .tier = "pinned",
        .confidence = 0.95,
    };
    try std.testing.expectEqualStrings("pref-dark-mode", delta.key);
    try std.testing.expectEqualStrings("user prefers dark mode", delta.content.?);
    try std.testing.expectEqualStrings("core", delta.category.?);
    try std.testing.expectEqualStrings("semantic", delta.kind.?);
    try std.testing.expectEqualStrings("pinned", delta.tier.?);
    try std.testing.expect(delta.confidence.? == 0.95);
}

test "TaskDelta defaults" {
    const delta = TaskDelta{ .task_id = "task-001" };
    try std.testing.expectEqualStrings("task-001", delta.task_id);
    try std.testing.expect(delta.status == null);
    try std.testing.expect(delta.title == null);
    try std.testing.expect(delta.priority == null);
    try std.testing.expect(delta.notes == null);
}

test "TaskDelta with fields" {
    const delta = TaskDelta{
        .task_id = "task-042",
        .status = "running",
        .title = "Deploy new version",
        .priority = "high",
        .notes = "Started by scheduler",
    };
    try std.testing.expectEqualStrings("task-042", delta.task_id);
    try std.testing.expectEqualStrings("running", delta.status.?);
    try std.testing.expectEqualStrings("Deploy new version", delta.title.?);
    try std.testing.expectEqualStrings("high", delta.priority.?);
}

test "EventDelta defaults" {
    const delta = EventDelta{ .event_id = "evt-001" };
    try std.testing.expectEqualStrings("evt-001", delta.event_id);
    try std.testing.expect(delta.severity == null);
    try std.testing.expect(delta.event_kind == null);
    try std.testing.expect(delta.summary == null);
    try std.testing.expect(delta.data_json == null);
}

test "EventDelta with fields" {
    const delta = EventDelta{
        .event_id = "evt-100",
        .severity = "info",
        .event_kind = "tool_call",
        .summary = "web_fetch completed",
        .data_json = "{\"url\":\"https://example.com\"}",
    };
    try std.testing.expectEqualStrings("evt-100", delta.event_id);
    try std.testing.expectEqualStrings("info", delta.severity.?);
    try std.testing.expectEqualStrings("tool_call", delta.event_kind.?);
}

test "SyncMessage validate — valid memory message" {
    const msg = memoryMessage(
        .{ .id = "huginn" },
        1,
        1700000000000,
        .create,
        "rec-001",
        .{ .key = "fact", .content = "sky is blue" },
    );
    try std.testing.expect(msg.validate());
}

test "SyncMessage validate — valid task message" {
    const msg = taskMessage(
        .{ .id = "muninn" },
        5,
        1700000000000,
        .update,
        "task-001",
        .{ .task_id = "task-001", .status = "completed" },
    );
    try std.testing.expect(msg.validate());
}

test "SyncMessage validate — valid event message" {
    const msg = eventMessage(
        .{ .id = "huginn" },
        10,
        1700000000000,
        .create,
        "evt-001",
        .{ .event_id = "evt-001", .severity = "info" },
    );
    try std.testing.expect(msg.validate());
}

test "SyncMessage validate — rejects empty node ID" {
    const msg = memoryMessage(
        .{ .id = "" },
        1,
        1700000000000,
        .create,
        "rec-001",
        .{ .key = "fact" },
    );
    try std.testing.expect(!msg.validate());
}

test "SyncMessage validate — rejects no payload" {
    const msg = SyncMessage{
        .header = .{
            .source_node = .{ .id = "huginn" },
            .sequence = 1,
            .timestamp = 1700000000000,
            .kind = .memory,
            .op = .create,
            .record_id = "rec-001",
        },
    };
    try std.testing.expect(!msg.validate());
}

test "SyncMessage validate — rejects mismatched payload kind" {
    // Header says memory, but we set task payload
    const msg = SyncMessage{
        .header = .{
            .source_node = .{ .id = "huginn" },
            .sequence = 1,
            .timestamp = 1700000000000,
            .kind = .memory,
            .op = .create,
            .record_id = "rec-001",
        },
        .task = .{ .task_id = "task-001" },
    };
    try std.testing.expect(!msg.validate());
}

test "SyncMessage validate — rejects multiple payloads" {
    const msg = SyncMessage{
        .header = .{
            .source_node = .{ .id = "huginn" },
            .sequence = 1,
            .timestamp = 1700000000000,
            .kind = .memory,
            .op = .create,
            .record_id = "rec-001",
        },
        .memory = .{ .key = "fact" },
        .task = .{ .task_id = "task-001" },
    };
    try std.testing.expect(!msg.validate());
}

test "SyncMessage validate — rejects wrong schema version" {
    var msg = memoryMessage(
        .{ .id = "huginn" },
        1,
        1700000000000,
        .create,
        "rec-001",
        .{ .key = "fact" },
    );
    msg.header.schema_version = 99;
    try std.testing.expect(!msg.validate());
}

test "memoryMessage constructor" {
    const msg = memoryMessage(
        .{ .id = "node-a" },
        42,
        1700000000000,
        .update,
        "mem-007",
        .{ .key = "greeting", .content = "hello world", .category = "core" },
    );
    try std.testing.expectEqualStrings("node-a", msg.header.source_node.id);
    try std.testing.expectEqual(@as(SequenceNum, 42), msg.header.sequence);
    try std.testing.expect(msg.header.kind == .memory);
    try std.testing.expect(msg.header.op == .update);
    try std.testing.expectEqualStrings("mem-007", msg.header.record_id);
    try std.testing.expectEqualStrings("greeting", msg.memory.?.key);
    try std.testing.expectEqualStrings("hello world", msg.memory.?.content.?);
    try std.testing.expect(msg.task == null);
    try std.testing.expect(msg.event == null);
}

test "taskMessage constructor" {
    const msg = taskMessage(
        .{ .id = "node-b" },
        7,
        1700000000000,
        .create,
        "task-099",
        .{ .task_id = "task-099", .status = "pending", .title = "New task" },
    );
    try std.testing.expect(msg.header.kind == .task);
    try std.testing.expectEqualStrings("task-099", msg.task.?.task_id);
    try std.testing.expect(msg.memory == null);
    try std.testing.expect(msg.event == null);
}

test "eventMessage constructor" {
    const msg = eventMessage(
        .{ .id = "node-c" },
        3,
        1700000000000,
        .create,
        "evt-055",
        .{ .event_id = "evt-055", .severity = "warn", .summary = "High latency" },
    );
    try std.testing.expect(msg.header.kind == .event);
    try std.testing.expectEqualStrings("evt-055", msg.event.?.event_id);
    try std.testing.expect(msg.memory == null);
    try std.testing.expect(msg.task == null);
}
