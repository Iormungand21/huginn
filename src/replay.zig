//! Replay mode skeleton for event timeline sessions.
//!
//! Provides types and helpers for reading back JSONL event timeline files
//! produced by `EventStore`. The reader parses lines into `ReplayEvent`
//! structs and supports basic filtering by kind, severity, session, and
//! time range. Full execution replay (re-running steps) is stubbed with
//! TODO markers for later stages.

const std = @import("std");
const events = @import("events.zig");
const EventSeverity = events.EventSeverity;
const EventKind = events.EventKind;

// ── Replay event (parsed from JSONL) ──────────────────────────────
/// A timeline event parsed from a JSONL line. All string fields are
/// slices into the caller-owned line buffer (no heap allocation).
pub const ReplayEvent = struct {
    id: []const u8 = "",
    timestamp_ns: i128 = 0,
    kind: EventKind = .system,
    severity: EventSeverity = .info,
    name: []const u8 = "",
    session_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    parent_span_id: ?[]const u8 = null,
    duration_ns: ?u64 = null,
    message: ?[]const u8 = null,
    component: ?[]const u8 = null,
};

// ── Replay filter ─────────────────────────────────────────────────
/// Filter criteria for selecting events during replay.
pub const ReplayFilter = struct {
    /// Only include events of this kind (null = all kinds).
    kind: ?EventKind = null,
    /// Minimum severity threshold (null = all severities).
    min_severity: ?EventSeverity = null,
    /// Only include events from this session (null = all sessions).
    session_id: ?[]const u8 = null,
    /// Only include events at or after this timestamp (null = no lower bound).
    start_ns: ?i128 = null,
    /// Only include events at or before this timestamp (null = no upper bound).
    end_ns: ?i128 = null,

    /// Returns true if the event passes all filter criteria.
    pub fn matches(self: *const ReplayFilter, ev: *const ReplayEvent) bool {
        if (self.kind) |k| {
            if (ev.kind != k) return false;
        }
        if (self.min_severity) |min_sev| {
            if (ev.severity.toOrdinal() < min_sev.toOrdinal()) return false;
        }
        if (self.session_id) |sid| {
            const ev_sid = ev.session_id orelse return false;
            if (!std.mem.eql(u8, ev_sid, sid)) return false;
        }
        if (self.start_ns) |start| {
            if (ev.timestamp_ns < start) return false;
        }
        if (self.end_ns) |end| {
            if (ev.timestamp_ns > end) return false;
        }
        return true;
    }
};

// ── Replay session summary ────────────────────────────────────────
/// Aggregate statistics from a replay pass over a timeline file.
pub const ReplaySessionSummary = struct {
    /// Total events read (before filtering).
    total_events: usize = 0,
    /// Events matching the active filter.
    matched_events: usize = 0,
    /// Earliest timestamp seen (nanoseconds).
    first_ts: ?i128 = null,
    /// Latest timestamp seen (nanoseconds).
    last_ts: ?i128 = null,
    /// Count of events per kind.
    kind_counts: [7]usize = .{ 0, 0, 0, 0, 0, 0, 0 },
    /// Count of events per severity.
    severity_counts: [4]usize = .{ 0, 0, 0, 0 },

    /// Record a single event into the summary.
    pub fn record(self: *ReplaySessionSummary, ev: *const ReplayEvent) void {
        self.total_events += 1;
        if (self.first_ts == null or ev.timestamp_ns < self.first_ts.?) {
            self.first_ts = ev.timestamp_ns;
        }
        if (self.last_ts == null or ev.timestamp_ns > self.last_ts.?) {
            self.last_ts = ev.timestamp_ns;
        }
        self.kind_counts[@intFromEnum(ev.kind)] += 1;
        self.severity_counts[ev.severity.toOrdinal()] += 1;
    }

    /// Wall-clock duration of the session in nanoseconds (null if <2 events).
    pub fn durationNs(self: *const ReplaySessionSummary) ?i128 {
        const first = self.first_ts orelse return null;
        const last = self.last_ts orelse return null;
        if (last <= first) return null;
        return last - first;
    }
};

// ── JSONL line parser ─────────────────────────────────────────────
/// Parse a single JSONL line into a `ReplayEvent`.
/// String fields point into `line` — the caller must keep `line` alive
/// while the returned event is in use.
/// Returns null if the line cannot be parsed.
pub fn parseEventLine(line: []const u8) ?ReplayEvent {
    if (line.len < 2) return null;
    if (line[0] != '{') return null;

    var ev = ReplayEvent{};

    ev.id = extractStringField(line, "\"id\":\"") orelse return null;
    ev.name = extractStringField(line, "\"name\":\"") orelse return null;
    ev.timestamp_ns = extractIntField(i128, line, "\"ts\":") orelse return null;

    if (extractStringField(line, "\"kind\":\"")) |k| {
        ev.kind = EventKind.fromString(k) orelse .system;
    }
    if (extractStringField(line, "\"severity\":\"")) |s| {
        ev.severity = EventSeverity.fromString(s) orelse .info;
    }
    ev.session_id = extractStringField(line, "\"session_id\":\"");
    ev.task_id = extractStringField(line, "\"task_id\":\"");
    ev.span_id = extractStringField(line, "\"span_id\":\"");
    ev.parent_span_id = extractStringField(line, "\"parent_span_id\":\"");
    ev.duration_ns = extractIntField(u64, line, "\"duration_ns\":");
    ev.message = extractStringField(line, "\"message\":\"");
    ev.component = extractStringField(line, "\"component\":\"");

    return ev;
}

/// Extract a quoted string value following `marker` in `line`.
/// Returns a slice into `line`.
fn extractStringField(line: []const u8, marker: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, marker) orelse return null;
    const start = idx + marker.len;
    if (start >= line.len) return null;
    // Find closing quote (no escape handling — event fields are plain ASCII)
    const end_rel = std.mem.indexOfScalar(u8, line[start..], '"') orelse return null;
    return line[start .. start + end_rel];
}

/// Extract a numeric value following `marker` in `line`.
fn extractIntField(comptime T: type, line: []const u8, marker: []const u8) ?T {
    const idx = std.mem.indexOf(u8, line, marker) orelse return null;
    const after = line[idx + marker.len ..];
    var end: usize = 0;
    for (after) |ch| {
        if ((ch >= '0' and ch <= '9') or (ch == '-' and end == 0)) {
            end += 1;
        } else break;
    }
    if (end == 0) return null;
    return std.fmt.parseInt(T, after[0..end], 10) catch null;
}

// ── Replay reader ─────────────────────────────────────────────────
/// Line-by-line reader over a JSONL event timeline file.
/// Reads one event at a time without loading the entire file into memory.
pub const ReplayReader = struct {
    path: []const u8,
    filter: ReplayFilter,
    summary: ReplaySessionSummary,

    pub fn init(path: []const u8) ReplayReader {
        return .{
            .path = path,
            .filter = .{},
            .summary = .{},
        };
    }

    pub fn initFiltered(path: []const u8, filter: ReplayFilter) ReplayReader {
        return .{
            .path = path,
            .filter = filter,
            .summary = .{},
        };
    }

    /// Scan the entire file and return a summary of matching events.
    /// Each parsed event is passed to `callback` if it matches the filter.
    /// Returns the summary on success, or null if the file cannot be opened.
    pub fn scan(self: *ReplayReader, buf: []u8, callback: ?*const fn (*const ReplayEvent) void) ?ReplaySessionSummary {
        const file = std.fs.cwd().openFile(self.path, .{}) catch return null;
        defer file.close();

        var pos: usize = 0;
        while (true) {
            const n = file.read(buf[pos..]) catch break;
            if (n == 0 and pos == 0) break;
            const filled = pos + n;

            var start: usize = 0;
            while (std.mem.indexOfScalar(u8, buf[start..filled], '\n')) |nl| {
                const line = buf[start .. start + nl];
                start += nl + 1;

                if (parseEventLine(line)) |ev| {
                    self.summary.record(&ev);
                    if (self.filter.matches(&ev)) {
                        self.summary.matched_events += 1;
                        if (callback) |cb| cb(&ev);
                    }
                }
            }

            if (start < filled) {
                std.mem.copyForwards(u8, buf[0 .. filled - start], buf[start..filled]);
                pos = filled - start;
            } else {
                pos = 0;
            }

            if (n == 0) break;
        }

        return self.summary;
    }

    // TODO(S3-OBS): replayStep() — re-execute a single event for debugging
    // TODO(S3-OBS): replaySession() — replay full session with pacing/callbacks
    // TODO(S3-OBS): exportFiltered() — write filtered events to a new JSONL file
};

// ── Tests ──────────────────────────────────────────────────────────

test "parseEventLine minimal" {
    const line = "{\"id\":\"e1\",\"ts\":100,\"kind\":\"system\",\"severity\":\"info\",\"name\":\"sys.boot\"}";
    const ev = parseEventLine(line).?;
    try std.testing.expectEqualStrings("e1", ev.id);
    try std.testing.expectEqual(@as(i128, 100), ev.timestamp_ns);
    try std.testing.expect(ev.kind == .system);
    try std.testing.expect(ev.severity == .info);
    try std.testing.expectEqualStrings("sys.boot", ev.name);
    try std.testing.expect(ev.session_id == null);
    try std.testing.expect(ev.duration_ns == null);
}

test "parseEventLine with optional fields" {
    const line = "{\"id\":\"e2\",\"ts\":200,\"kind\":\"agent\",\"severity\":\"error\",\"name\":\"agent.fail\",\"session_id\":\"s1\",\"task_id\":\"t1\",\"duration_ns\":5000,\"message\":\"timeout\",\"component\":\"planner\"}";
    const ev = parseEventLine(line).?;
    try std.testing.expectEqualStrings("e2", ev.id);
    try std.testing.expectEqual(@as(i128, 200), ev.timestamp_ns);
    try std.testing.expect(ev.kind == .agent);
    try std.testing.expect(ev.severity == .err);
    try std.testing.expectEqualStrings("agent.fail", ev.name);
    try std.testing.expectEqualStrings("s1", ev.session_id.?);
    try std.testing.expectEqualStrings("t1", ev.task_id.?);
    try std.testing.expectEqual(@as(u64, 5000), ev.duration_ns.?);
    try std.testing.expectEqualStrings("timeout", ev.message.?);
    try std.testing.expectEqualStrings("planner", ev.component.?);
}

test "parseEventLine invalid returns null" {
    try std.testing.expect(parseEventLine("") == null);
    try std.testing.expect(parseEventLine("x") == null);
    try std.testing.expect(parseEventLine("not json") == null);
    // Missing required id field
    try std.testing.expect(parseEventLine("{\"ts\":1,\"name\":\"x\"}") == null);
}

test "ReplayFilter matches all by default" {
    const filter = ReplayFilter{};
    const ev = ReplayEvent{ .id = "e1", .timestamp_ns = 100, .name = "test" };
    try std.testing.expect(filter.matches(&ev));
}

test "ReplayFilter kind filter" {
    const filter = ReplayFilter{ .kind = .tool };
    const ev1 = ReplayEvent{ .id = "e1", .kind = .tool, .name = "t" };
    const ev2 = ReplayEvent{ .id = "e2", .kind = .agent, .name = "a" };
    try std.testing.expect(filter.matches(&ev1));
    try std.testing.expect(!filter.matches(&ev2));
}

test "ReplayFilter severity threshold" {
    const filter = ReplayFilter{ .min_severity = .warn };
    const ev_debug = ReplayEvent{ .id = "e1", .severity = .debug, .name = "d" };
    const ev_warn = ReplayEvent{ .id = "e2", .severity = .warn, .name = "w" };
    const ev_err = ReplayEvent{ .id = "e3", .severity = .err, .name = "e" };
    try std.testing.expect(!filter.matches(&ev_debug));
    try std.testing.expect(filter.matches(&ev_warn));
    try std.testing.expect(filter.matches(&ev_err));
}

test "ReplayFilter session filter" {
    const filter = ReplayFilter{ .session_id = "sess-abc" };
    const ev1 = ReplayEvent{ .id = "e1", .session_id = "sess-abc", .name = "a" };
    const ev2 = ReplayEvent{ .id = "e2", .session_id = "sess-xyz", .name = "b" };
    const ev3 = ReplayEvent{ .id = "e3", .name = "c" }; // no session
    try std.testing.expect(filter.matches(&ev1));
    try std.testing.expect(!filter.matches(&ev2));
    try std.testing.expect(!filter.matches(&ev3));
}

test "ReplayFilter time range" {
    const filter = ReplayFilter{ .start_ns = 100, .end_ns = 300 };
    const ev_before = ReplayEvent{ .id = "e1", .timestamp_ns = 50, .name = "a" };
    const ev_in = ReplayEvent{ .id = "e2", .timestamp_ns = 200, .name = "b" };
    const ev_after = ReplayEvent{ .id = "e3", .timestamp_ns = 400, .name = "c" };
    const ev_start = ReplayEvent{ .id = "e4", .timestamp_ns = 100, .name = "d" };
    const ev_end = ReplayEvent{ .id = "e5", .timestamp_ns = 300, .name = "e" };
    try std.testing.expect(!filter.matches(&ev_before));
    try std.testing.expect(filter.matches(&ev_in));
    try std.testing.expect(!filter.matches(&ev_after));
    try std.testing.expect(filter.matches(&ev_start));
    try std.testing.expect(filter.matches(&ev_end));
}

test "ReplaySessionSummary record and duration" {
    var summary = ReplaySessionSummary{};
    const ev1 = ReplayEvent{ .id = "e1", .timestamp_ns = 1000, .kind = .agent, .severity = .info, .name = "a" };
    const ev2 = ReplayEvent{ .id = "e2", .timestamp_ns = 5000, .kind = .tool, .severity = .warn, .name = "b" };
    const ev3 = ReplayEvent{ .id = "e3", .timestamp_ns = 3000, .kind = .agent, .severity = .err, .name = "c" };

    summary.record(&ev1);
    summary.record(&ev2);
    summary.record(&ev3);

    try std.testing.expectEqual(@as(usize, 3), summary.total_events);
    try std.testing.expectEqual(@as(i128, 1000), summary.first_ts.?);
    try std.testing.expectEqual(@as(i128, 5000), summary.last_ts.?);
    try std.testing.expectEqual(@as(i128, 4000), summary.durationNs().?);

    // kind_counts: agent=2, tool=1
    try std.testing.expectEqual(@as(usize, 2), summary.kind_counts[@intFromEnum(EventKind.agent)]);
    try std.testing.expectEqual(@as(usize, 1), summary.kind_counts[@intFromEnum(EventKind.tool)]);
    // severity_counts: info=1, warn=1, err=1
    try std.testing.expectEqual(@as(usize, 1), summary.severity_counts[EventSeverity.info.toOrdinal()]);
    try std.testing.expectEqual(@as(usize, 1), summary.severity_counts[EventSeverity.warn.toOrdinal()]);
    try std.testing.expectEqual(@as(usize, 1), summary.severity_counts[EventSeverity.err.toOrdinal()]);
}

test "ReplaySessionSummary duration with single event" {
    var summary = ReplaySessionSummary{};
    const ev = ReplayEvent{ .id = "e1", .timestamp_ns = 1000, .name = "a" };
    summary.record(&ev);
    try std.testing.expect(summary.durationNs() == null);
}

test "ReplayReader scan with file" {
    const path = "/tmp/nullclaw_replay_test.jsonl";
    // Write test data
    {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll("{\"id\":\"e1\",\"ts\":100,\"kind\":\"agent\",\"severity\":\"info\",\"name\":\"agent.start\",\"session_id\":\"s1\"}\n");
        try file.writeAll("{\"id\":\"e2\",\"ts\":200,\"kind\":\"tool\",\"severity\":\"warn\",\"name\":\"tool.call\",\"session_id\":\"s1\"}\n");
        try file.writeAll("{\"id\":\"e3\",\"ts\":300,\"kind\":\"agent\",\"severity\":\"info\",\"name\":\"agent.end\",\"session_id\":\"s2\"}\n");
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    // Scan all events
    var reader = ReplayReader.init(path);
    var buf: [4096]u8 = undefined;
    const summary = reader.scan(&buf, null).?;
    try std.testing.expectEqual(@as(usize, 3), summary.total_events);
    try std.testing.expectEqual(@as(usize, 3), summary.matched_events);
    try std.testing.expectEqual(@as(i128, 100), summary.first_ts.?);
    try std.testing.expectEqual(@as(i128, 300), summary.last_ts.?);
}

test "ReplayReader scan with filter" {
    const path = "/tmp/nullclaw_replay_filter_test.jsonl";
    {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll("{\"id\":\"e1\",\"ts\":100,\"kind\":\"agent\",\"severity\":\"info\",\"name\":\"agent.start\"}\n");
        try file.writeAll("{\"id\":\"e2\",\"ts\":200,\"kind\":\"tool\",\"severity\":\"warn\",\"name\":\"tool.call\"}\n");
        try file.writeAll("{\"id\":\"e3\",\"ts\":300,\"kind\":\"agent\",\"severity\":\"err\",\"name\":\"agent.fail\"}\n");
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    // Filter: only tool events
    var reader = ReplayReader.initFiltered(path, .{ .kind = .tool });
    var buf: [4096]u8 = undefined;
    const summary = reader.scan(&buf, null).?;
    try std.testing.expectEqual(@as(usize, 3), summary.total_events);
    try std.testing.expectEqual(@as(usize, 1), summary.matched_events);
}

test "ReplayReader scan missing file" {
    var reader = ReplayReader.init("/tmp/does_not_exist_replay.jsonl");
    var buf: [4096]u8 = undefined;
    try std.testing.expect(reader.scan(&buf, null) == null);
}

test "extractStringField basic" {
    const line = "{\"id\":\"hello\",\"name\":\"world\"}";
    const id = extractStringField(line, "\"id\":\"").?;
    try std.testing.expectEqualStrings("hello", id);
    const name = extractStringField(line, "\"name\":\"").?;
    try std.testing.expectEqualStrings("world", name);
}

test "extractStringField missing returns null" {
    const line = "{\"id\":\"hello\"}";
    try std.testing.expect(extractStringField(line, "\"missing\":\"") == null);
}

test "extractIntField basic" {
    const line = "{\"ts\":12345,\"duration_ns\":999}";
    const ts = extractIntField(i128, line, "\"ts\":").?;
    try std.testing.expectEqual(@as(i128, 12345), ts);
    const dur = extractIntField(u64, line, "\"duration_ns\":").?;
    try std.testing.expectEqual(@as(u64, 999), dur);
}

test "extractIntField missing returns null" {
    const line = "{\"ts\":100}";
    try std.testing.expect(extractIntField(u64, line, "\"missing\":") == null);
}
