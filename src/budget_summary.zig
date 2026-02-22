//! Budget metrics summary helpers for diagnostics and status reporting.
//!
//! Aggregates cost and latency data from the event timeline and cost
//! tracker into a single report suitable for `doctor` / `status` output.
//! All helpers are pure functions over existing data structures — they do
//! not perform I/O themselves beyond reading timeline JSONL files.

const std = @import("std");
const events = @import("events.zig");
const EventKind = events.EventKind;
const EventSeverity = events.EventSeverity;
const cost_mod = @import("cost.zig");
const CostSummary = cost_mod.CostSummary;
const replay = @import("replay.zig");
const ReplayEvent = replay.ReplayEvent;
const ReplayReader = replay.ReplayReader;

// ── Latency stats ─────────────────────────────────────────────────
/// Latency statistics derived from event durations.
pub const LatencyStats = struct {
    /// Number of events with a duration value.
    count: usize = 0,
    /// Sum of all durations (nanoseconds).
    total_ns: u64 = 0,
    /// Minimum duration seen (nanoseconds).
    min_ns: ?u64 = null,
    /// Maximum duration seen (nanoseconds).
    max_ns: ?u64 = null,

    /// Record a single duration.
    pub fn record(self: *LatencyStats, duration_ns: u64) void {
        self.count += 1;
        self.total_ns +|= duration_ns;
        if (self.min_ns == null or duration_ns < self.min_ns.?) {
            self.min_ns = duration_ns;
        }
        if (self.max_ns == null or duration_ns > self.max_ns.?) {
            self.max_ns = duration_ns;
        }
    }

    /// Mean duration in nanoseconds (null if no durations recorded).
    pub fn meanNs(self: *const LatencyStats) ?u64 {
        if (self.count == 0) return null;
        return self.total_ns / @as(u64, @intCast(self.count));
    }

    /// Mean duration in milliseconds (null if no durations recorded).
    pub fn meanMs(self: *const LatencyStats) ?f64 {
        const mean = self.meanNs() orelse return null;
        return @as(f64, @floatFromInt(mean)) / 1_000_000.0;
    }
};

// ── Budget metrics ────────────────────────────────────────────────
/// Combined cost and latency metrics for a session or time window.
pub const BudgetMetrics = struct {
    /// Cost summary (from CostTracker).
    cost: CostSummary = .{},
    /// Latency stats for LLM requests.
    llm_latency: LatencyStats = .{},
    /// Latency stats for tool calls.
    tool_latency: LatencyStats = .{},
    /// Total event count in the window.
    total_events: usize = 0,
    /// Error event count in the window.
    error_events: usize = 0,

    /// Record an event's latency into the appropriate bucket.
    pub fn recordEvent(self: *BudgetMetrics, ev: *const ReplayEvent) void {
        self.total_events += 1;
        if (ev.severity == .err) {
            self.error_events += 1;
        }
        if (ev.duration_ns) |dur| {
            switch (ev.kind) {
                .llm => self.llm_latency.record(dur),
                .tool => self.tool_latency.record(dur),
                else => {},
            }
        }
    }

    /// Error rate as a fraction [0.0, 1.0] (null if no events).
    pub fn errorRate(self: *const BudgetMetrics) ?f64 {
        if (self.total_events == 0) return null;
        return @as(f64, @floatFromInt(self.error_events)) / @as(f64, @floatFromInt(self.total_events));
    }
};

// ── Summary builder ───────────────────────────────────────────────
/// Build a `BudgetMetrics` from a timeline JSONL file and cost summary.
/// Returns null if the events file cannot be read.
pub fn buildMetrics(events_path: []const u8, cost_summary: CostSummary) ?BudgetMetrics {
    var metrics = BudgetMetrics{};
    metrics.cost = cost_summary;

    var reader = ReplayReader.init(events_path);
    var buf: [8192]u8 = undefined;

    // We use the scan callback mechanism — but since we can't capture
    // state via function pointer, we collect stats from the summary.
    const summary = reader.scan(&buf, null) orelse return null;

    metrics.total_events = summary.total_events;
    metrics.error_events = summary.severity_counts[EventSeverity.err.toOrdinal()];

    // Note: per-kind latency stats require a second pass or integrated
    // callback. For the skeleton we report event/error counts from the
    // summary. Full latency aggregation is deferred to when we add a
    // stateful scan callback (TODO: S3-OBS).
    return metrics;
}

// ── Diagnostic report formatter ───────────────────────────────────
/// Format a budget metrics report into a fixed buffer for doctor/status output.
/// Returns the formatted slice, or null if the buffer is too small.
pub fn formatReport(metrics: *const BudgetMetrics, buf: []u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("Budget Summary:\n") catch return null;

    // Cost section
    w.print("  Cost (session):  ${d:.6}\n", .{metrics.cost.session_cost_usd}) catch return null;
    w.print("  Cost (daily):    ${d:.6}\n", .{metrics.cost.daily_cost_usd}) catch return null;
    w.print("  Cost (monthly):  ${d:.6}\n", .{metrics.cost.monthly_cost_usd}) catch return null;
    w.print("  Tokens (total):  {d}\n", .{metrics.cost.total_tokens}) catch return null;
    w.print("  Requests:        {d}\n", .{metrics.cost.request_count}) catch return null;

    // Latency section
    w.writeAll("  LLM latency:     ") catch return null;
    if (metrics.llm_latency.meanMs()) |ms| {
        w.print("{d:.2}ms avg ({d} calls)\n", .{ ms, metrics.llm_latency.count }) catch return null;
    } else {
        w.writeAll("(no data)\n") catch return null;
    }

    w.writeAll("  Tool latency:    ") catch return null;
    if (metrics.tool_latency.meanMs()) |ms| {
        w.print("{d:.2}ms avg ({d} calls)\n", .{ ms, metrics.tool_latency.count }) catch return null;
    } else {
        w.writeAll("(no data)\n") catch return null;
    }

    // Events section
    w.print("  Events (total):  {d}\n", .{metrics.total_events}) catch return null;
    w.print("  Events (errors): {d}\n", .{metrics.error_events}) catch return null;
    if (metrics.errorRate()) |rate| {
        w.print("  Error rate:      {d:.2}%\n", .{rate * 100.0}) catch return null;
    }

    return fbs.getWritten();
}

// ── Tests ──────────────────────────────────────────────────────────

test "LatencyStats empty" {
    const stats = LatencyStats{};
    try std.testing.expect(stats.meanNs() == null);
    try std.testing.expect(stats.meanMs() == null);
    try std.testing.expectEqual(@as(usize, 0), stats.count);
}

test "LatencyStats single record" {
    var stats = LatencyStats{};
    stats.record(2_000_000); // 2ms
    try std.testing.expectEqual(@as(usize, 1), stats.count);
    try std.testing.expectEqual(@as(u64, 2_000_000), stats.meanNs().?);
    try std.testing.expectEqual(@as(u64, 2_000_000), stats.min_ns.?);
    try std.testing.expectEqual(@as(u64, 2_000_000), stats.max_ns.?);
    // meanMs should be 2.0
    const ms = stats.meanMs().?;
    try std.testing.expect(@abs(ms - 2.0) < 0.01);
}

test "LatencyStats multiple records" {
    var stats = LatencyStats{};
    stats.record(1_000_000); // 1ms
    stats.record(3_000_000); // 3ms
    stats.record(2_000_000); // 2ms

    try std.testing.expectEqual(@as(usize, 3), stats.count);
    try std.testing.expectEqual(@as(u64, 6_000_000), stats.total_ns);
    try std.testing.expectEqual(@as(u64, 2_000_000), stats.meanNs().?);
    try std.testing.expectEqual(@as(u64, 1_000_000), stats.min_ns.?);
    try std.testing.expectEqual(@as(u64, 3_000_000), stats.max_ns.?);
}

test "BudgetMetrics recordEvent counts" {
    var metrics = BudgetMetrics{};
    const ev1 = ReplayEvent{ .id = "e1", .kind = .llm, .severity = .info, .name = "llm.req", .duration_ns = 500_000 };
    const ev2 = ReplayEvent{ .id = "e2", .kind = .tool, .severity = .err, .name = "tool.fail", .duration_ns = 100_000 };
    const ev3 = ReplayEvent{ .id = "e3", .kind = .agent, .severity = .info, .name = "agent.step" };

    metrics.recordEvent(&ev1);
    metrics.recordEvent(&ev2);
    metrics.recordEvent(&ev3);

    try std.testing.expectEqual(@as(usize, 3), metrics.total_events);
    try std.testing.expectEqual(@as(usize, 1), metrics.error_events);
    try std.testing.expectEqual(@as(usize, 1), metrics.llm_latency.count);
    try std.testing.expectEqual(@as(usize, 1), metrics.tool_latency.count);
    try std.testing.expectEqual(@as(u64, 500_000), metrics.llm_latency.total_ns);
    try std.testing.expectEqual(@as(u64, 100_000), metrics.tool_latency.total_ns);
}

test "BudgetMetrics errorRate" {
    var metrics = BudgetMetrics{};
    try std.testing.expect(metrics.errorRate() == null);

    const ev_ok = ReplayEvent{ .id = "e1", .severity = .info, .name = "ok" };
    const ev_err = ReplayEvent{ .id = "e2", .severity = .err, .name = "fail" };
    metrics.recordEvent(&ev_ok);
    metrics.recordEvent(&ev_ok);
    metrics.recordEvent(&ev_err);
    metrics.recordEvent(&ev_ok);

    const rate = metrics.errorRate().?;
    try std.testing.expect(@abs(rate - 0.25) < 0.01);
}

test "formatReport with data" {
    const metrics = BudgetMetrics{
        .cost = .{
            .session_cost_usd = 0.0105,
            .daily_cost_usd = 0.05,
            .monthly_cost_usd = 1.25,
            .total_tokens = 15000,
            .request_count = 10,
        },
        .total_events = 42,
        .error_events = 2,
    };

    var buf: [2048]u8 = undefined;
    const report = formatReport(&metrics, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, report, "Budget Summary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Tokens (total):  15000") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Requests:        10") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Events (total):  42") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Events (errors): 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "LLM latency:     (no data)") != null);
}

test "formatReport buffer too small" {
    const metrics = BudgetMetrics{};
    var buf: [5]u8 = undefined;
    try std.testing.expect(formatReport(&metrics, &buf) == null);
}

test "buildMetrics with file" {
    const path = "/tmp/nullclaw_budget_test.jsonl";
    {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll("{\"id\":\"e1\",\"ts\":100,\"kind\":\"llm\",\"severity\":\"info\",\"name\":\"llm.req\"}\n");
        try file.writeAll("{\"id\":\"e2\",\"ts\":200,\"kind\":\"tool\",\"severity\":\"error\",\"name\":\"tool.fail\"}\n");
        try file.writeAll("{\"id\":\"e3\",\"ts\":300,\"kind\":\"system\",\"severity\":\"info\",\"name\":\"sys.done\"}\n");
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    const cost_summary = CostSummary{
        .session_cost_usd = 0.01,
        .total_tokens = 1000,
        .request_count = 2,
    };
    const metrics = buildMetrics(path, cost_summary).?;
    try std.testing.expectEqual(@as(usize, 3), metrics.total_events);
    try std.testing.expectEqual(@as(usize, 1), metrics.error_events);
    try std.testing.expect(@abs(metrics.cost.session_cost_usd - 0.01) < 0.001);
}

test "buildMetrics missing file returns null" {
    const cost_summary = CostSummary{};
    try std.testing.expect(buildMetrics("/tmp/nonexistent_budget.jsonl", cost_summary) == null);
}
