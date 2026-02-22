//! Structured event timeline primitives for observability.
//!
//! Provides `EventSeverity`, `EventKind`, and `TimelineEvent` types for
//! recording structured events with IDs, timestamps, and session/task
//! correlation fields. These complement the existing `ObserverEvent` union
//! in `observability.zig` by adding a richer, persistence-ready schema.
//! Actual emission into the event pipeline is deferred to later stages.

const std = @import("std");

// ── Event severity ─────────────────────────────────────────────────
/// Severity level for a timeline event.
pub const EventSeverity = enum {
    /// Verbose trace-level output.
    debug,
    /// Normal operational event.
    info,
    /// Potentially problematic but recoverable situation.
    warn,
    /// Failure requiring attention.
    err,

    pub fn toString(self: EventSeverity) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }

    pub fn fromString(s: []const u8) ?EventSeverity {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }

    /// Numeric ordering (higher = more severe).
    pub fn toOrdinal(self: EventSeverity) u8 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .err => 3,
        };
    }
};

// ── Event kind ─────────────────────────────────────────────────────
/// High-level category for a timeline event.
pub const EventKind = enum {
    /// Agent lifecycle events (start, end, turn).
    agent,
    /// LLM request/response events.
    llm,
    /// Tool invocation events.
    tool,
    /// Channel message events (inbound/outbound).
    channel,
    /// Task state transitions.
    task,
    /// Memory operations (store, recall, forget).
    memory,
    /// System-level events (heartbeat, health, config).
    system,

    pub fn toString(self: EventKind) []const u8 {
        return switch (self) {
            .agent => "agent",
            .llm => "llm",
            .tool => "tool",
            .channel => "channel",
            .task => "task",
            .memory => "memory",
            .system => "system",
        };
    }

    pub fn fromString(s: []const u8) ?EventKind {
        if (std.mem.eql(u8, s, "agent")) return .agent;
        if (std.mem.eql(u8, s, "llm")) return .llm;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        if (std.mem.eql(u8, s, "channel")) return .channel;
        if (std.mem.eql(u8, s, "task")) return .task;
        if (std.mem.eql(u8, s, "memory")) return .memory;
        if (std.mem.eql(u8, s, "system")) return .system;
        return null;
    }
};

// ── Timeline event ─────────────────────────────────────────────────
/// A structured event with correlation IDs and timing for the event timeline.
///
/// Designed to be serializable as JSONL for replay, audit, and debugging.
/// Fields mirror common distributed-tracing conventions (trace/span IDs,
/// parent span, duration) while staying lightweight for local-first use.
pub const TimelineEvent = struct {
    /// Unique event identifier (e.g. monotonic counter or UUID).
    id: []const u8,
    /// Nanosecond-precision timestamp (from `std.time.nanoTimestamp`).
    timestamp_ns: i128,
    /// High-level event category.
    kind: EventKind = .system,
    /// Severity level.
    severity: EventSeverity = .info,
    /// Dot-separated event name (e.g. "agent.start", "tool.call.shell").
    name: []const u8,
    /// Session correlation ID (null if not session-scoped).
    session_id: ?[]const u8 = null,
    /// Task correlation ID (null if not task-scoped).
    task_id: ?[]const u8 = null,
    /// Span ID for this event (null for point-in-time events).
    span_id: ?[]const u8 = null,
    /// Parent span ID for nesting (null if top-level).
    parent_span_id: ?[]const u8 = null,
    /// Duration in nanoseconds (null for instantaneous events).
    duration_ns: ?u64 = null,
    /// Human-readable description or payload.
    message: ?[]const u8 = null,
    /// Originating component (e.g. "gateway", "heartbeat", "planner").
    component: ?[]const u8 = null,

    /// Free all heap-allocated fields.
    pub fn deinit(self: *const TimelineEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.session_id) |s| allocator.free(s);
        if (self.task_id) |t| allocator.free(t);
        if (self.span_id) |s| allocator.free(s);
        if (self.parent_span_id) |p| allocator.free(p);
        if (self.message) |m| allocator.free(m);
        if (self.component) |c| allocator.free(c);
    }

    /// Format the event as a JSONL line into the provided buffer.
    /// Returns the formatted slice, or null if the buffer is too small.
    pub fn formatJsonLine(self: *const TimelineEvent, buf: []u8) ?[]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();

        w.writeAll("{\"id\":\"") catch return null;
        w.writeAll(self.id) catch return null;
        w.writeAll("\",\"ts\":") catch return null;
        w.print("{d}", .{self.timestamp_ns}) catch return null;
        w.writeAll(",\"kind\":\"") catch return null;
        w.writeAll(self.kind.toString()) catch return null;
        w.writeAll("\",\"severity\":\"") catch return null;
        w.writeAll(self.severity.toString()) catch return null;
        w.writeAll("\",\"name\":\"") catch return null;
        w.writeAll(self.name) catch return null;
        w.writeByte('"') catch return null;

        if (self.session_id) |sid| {
            w.writeAll(",\"session_id\":\"") catch return null;
            w.writeAll(sid) catch return null;
            w.writeByte('"') catch return null;
        }
        if (self.task_id) |tid| {
            w.writeAll(",\"task_id\":\"") catch return null;
            w.writeAll(tid) catch return null;
            w.writeByte('"') catch return null;
        }
        if (self.span_id) |sid| {
            w.writeAll(",\"span_id\":\"") catch return null;
            w.writeAll(sid) catch return null;
            w.writeByte('"') catch return null;
        }
        if (self.parent_span_id) |pid| {
            w.writeAll(",\"parent_span_id\":\"") catch return null;
            w.writeAll(pid) catch return null;
            w.writeByte('"') catch return null;
        }
        if (self.duration_ns) |dur| {
            w.writeAll(",\"duration_ns\":") catch return null;
            w.print("{d}", .{dur}) catch return null;
        }
        if (self.message) |msg| {
            w.writeAll(",\"message\":\"") catch return null;
            w.writeAll(msg) catch return null;
            w.writeByte('"') catch return null;
        }
        if (self.component) |comp| {
            w.writeAll(",\"component\":\"") catch return null;
            w.writeAll(comp) catch return null;
            w.writeByte('"') catch return null;
        }

        w.writeByte('}') catch return null;
        return fbs.getWritten();
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "EventSeverity toString roundtrip" {
    try std.testing.expectEqualStrings("debug", EventSeverity.debug.toString());
    try std.testing.expectEqualStrings("info", EventSeverity.info.toString());
    try std.testing.expectEqualStrings("warn", EventSeverity.warn.toString());
    try std.testing.expectEqualStrings("error", EventSeverity.err.toString());
}

test "EventSeverity fromString valid" {
    try std.testing.expect(EventSeverity.fromString("debug").? == .debug);
    try std.testing.expect(EventSeverity.fromString("info").? == .info);
    try std.testing.expect(EventSeverity.fromString("warn").? == .warn);
    try std.testing.expect(EventSeverity.fromString("error").? == .err);
}

test "EventSeverity fromString invalid returns null" {
    try std.testing.expect(EventSeverity.fromString("bogus") == null);
    try std.testing.expect(EventSeverity.fromString("") == null);
    try std.testing.expect(EventSeverity.fromString("INFO") == null);
}

test "EventSeverity toOrdinal ordering" {
    try std.testing.expect(EventSeverity.debug.toOrdinal() < EventSeverity.info.toOrdinal());
    try std.testing.expect(EventSeverity.info.toOrdinal() < EventSeverity.warn.toOrdinal());
    try std.testing.expect(EventSeverity.warn.toOrdinal() < EventSeverity.err.toOrdinal());
}

test "EventKind toString roundtrip" {
    const cases = [_]struct { k: EventKind, str: []const u8 }{
        .{ .k = .agent, .str = "agent" },
        .{ .k = .llm, .str = "llm" },
        .{ .k = .tool, .str = "tool" },
        .{ .k = .channel, .str = "channel" },
        .{ .k = .task, .str = "task" },
        .{ .k = .memory, .str = "memory" },
        .{ .k = .system, .str = "system" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.str, c.k.toString());
    }
}

test "EventKind fromString valid" {
    try std.testing.expect(EventKind.fromString("agent").? == .agent);
    try std.testing.expect(EventKind.fromString("llm").? == .llm);
    try std.testing.expect(EventKind.fromString("tool").? == .tool);
    try std.testing.expect(EventKind.fromString("channel").? == .channel);
    try std.testing.expect(EventKind.fromString("task").? == .task);
    try std.testing.expect(EventKind.fromString("memory").? == .memory);
    try std.testing.expect(EventKind.fromString("system").? == .system);
}

test "EventKind fromString invalid returns null" {
    try std.testing.expect(EventKind.fromString("bogus") == null);
    try std.testing.expect(EventKind.fromString("") == null);
}

test "TimelineEvent defaults" {
    const ev = TimelineEvent{
        .id = "evt-001",
        .timestamp_ns = 1000000,
        .name = "test.event",
    };
    try std.testing.expect(ev.kind == .system);
    try std.testing.expect(ev.severity == .info);
    try std.testing.expect(ev.session_id == null);
    try std.testing.expect(ev.task_id == null);
    try std.testing.expect(ev.span_id == null);
    try std.testing.expect(ev.parent_span_id == null);
    try std.testing.expect(ev.duration_ns == null);
    try std.testing.expect(ev.message == null);
    try std.testing.expect(ev.component == null);
}

test "TimelineEvent with all fields" {
    const ev = TimelineEvent{
        .id = "evt-042",
        .timestamp_ns = 1708617600000000000,
        .kind = .tool,
        .severity = .warn,
        .name = "tool.call.shell",
        .session_id = "sess-abc",
        .task_id = "task-123",
        .span_id = "span-001",
        .parent_span_id = "span-000",
        .duration_ns = 50_000_000,
        .message = "shell command timed out",
        .component = "agent",
    };
    try std.testing.expectEqualStrings("evt-042", ev.id);
    try std.testing.expectEqual(@as(i128, 1708617600000000000), ev.timestamp_ns);
    try std.testing.expect(ev.kind == .tool);
    try std.testing.expect(ev.severity == .warn);
    try std.testing.expectEqualStrings("tool.call.shell", ev.name);
    try std.testing.expectEqualStrings("sess-abc", ev.session_id.?);
    try std.testing.expectEqualStrings("task-123", ev.task_id.?);
    try std.testing.expectEqualStrings("span-001", ev.span_id.?);
    try std.testing.expectEqualStrings("span-000", ev.parent_span_id.?);
    try std.testing.expectEqual(@as(u64, 50_000_000), ev.duration_ns.?);
    try std.testing.expectEqualStrings("shell command timed out", ev.message.?);
    try std.testing.expectEqualStrings("agent", ev.component.?);
}

test "TimelineEvent formatJsonLine minimal" {
    const ev = TimelineEvent{
        .id = "e1",
        .timestamp_ns = 100,
        .name = "sys.boot",
    };
    var buf: [4096]u8 = undefined;
    const line = ev.formatJsonLine(&buf).?;
    // Verify required fields are present
    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\":\"e1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"ts\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"severity\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"name\":\"sys.boot\"") != null);
    // Optional fields should be absent
    try std.testing.expect(std.mem.indexOf(u8, line, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "task_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "duration_ns") == null);
}

test "TimelineEvent formatJsonLine with optional fields" {
    const ev = TimelineEvent{
        .id = "e2",
        .timestamp_ns = 200,
        .kind = .agent,
        .severity = .err,
        .name = "agent.fail",
        .session_id = "s1",
        .task_id = "t1",
        .duration_ns = 5000,
        .message = "timeout",
        .component = "planner",
    };
    var buf: [4096]u8 = undefined;
    const line = ev.formatJsonLine(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, line, "\"session_id\":\"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"task_id\":\"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"duration_ns\":5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"message\":\"timeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"component\":\"planner\"") != null);
}

test "TimelineEvent formatJsonLine buffer too small" {
    const ev = TimelineEvent{
        .id = "e3",
        .timestamp_ns = 300,
        .name = "test",
    };
    var buf: [5]u8 = undefined;
    try std.testing.expect(ev.formatJsonLine(&buf) == null);
}

test "TimelineEvent formatJsonLine starts and ends with braces" {
    const ev = TimelineEvent{
        .id = "e4",
        .timestamp_ns = 400,
        .name = "check",
    };
    var buf: [4096]u8 = undefined;
    const line = ev.formatJsonLine(&buf).?;
    try std.testing.expect(line[0] == '{');
    try std.testing.expect(line[line.len - 1] == '}');
}
