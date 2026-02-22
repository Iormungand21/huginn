//! Persistent task state machine primitives for long-running work.
//!
//! Provides `TaskStatus`, `TaskPriority`, `StepRecord`, and `TaskRecord`
//! types for tracking multi-step autonomous tasks through their lifecycle.
//! These are serialization-ready scaffolds — persistence and daemon
//! integration will be added in later stages.

const std = @import("std");

// ── Task status ────────────────────────────────────────────────────
/// Lifecycle status of a task.
pub const TaskStatus = enum {
    /// Task has been created but not yet started.
    pending,
    /// Task is actively being executed.
    running,
    /// Task completed successfully.
    completed,
    /// Task failed after exhausting retries.
    failed,
    /// Task was cancelled by the user or system.
    cancelled,
    /// Task is waiting on an external dependency or resource.
    blocked,

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
            .blocked => "blocked",
        };
    }

    pub fn fromString(s: []const u8) ?TaskStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return null;
    }

    /// Whether the task is in a terminal state (no further transitions expected).
    pub fn isTerminal(self: TaskStatus) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            .pending, .running, .blocked => false,
        };
    }
};

// ── Task priority ──────────────────────────────────────────────────
/// Priority level for task scheduling.
pub const TaskPriority = enum {
    low,
    normal,
    high,
    critical,

    pub fn toString(self: TaskPriority) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .high => "high",
            .critical => "critical",
        };
    }

    pub fn fromString(s: []const u8) ?TaskPriority {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "critical")) return .critical;
        return null;
    }

    /// Numeric ordering for comparisons (higher = more urgent).
    pub fn toOrdinal(self: TaskPriority) u8 {
        return switch (self) {
            .low => 0,
            .normal => 1,
            .high => 2,
            .critical => 3,
        };
    }
};

// ── Step record ────────────────────────────────────────────────────
/// A single step within a multi-step task.
pub const StepRecord = struct {
    /// Step index (0-based) within the parent task.
    index: u32,
    /// Human-readable label for this step.
    label: []const u8,
    /// Current status of this step.
    status: TaskStatus = .pending,
    /// Number of retry attempts consumed so far.
    retries: u32 = 0,
    /// ISO-8601 timestamp when this step started (null if not yet started).
    started_at: ?[]const u8 = null,
    /// ISO-8601 timestamp when this step finished (null if not yet finished).
    finished_at: ?[]const u8 = null,
    /// Optional error message if the step failed.
    error_msg: ?[]const u8 = null,

    /// Free all heap-allocated fields.
    pub fn deinit(self: *const StepRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.started_at) |s| allocator.free(s);
        if (self.finished_at) |f| allocator.free(f);
        if (self.error_msg) |e| allocator.free(e);
    }
};

// ── Task record ────────────────────────────────────────────────────
/// A persistent record for a long-running task.
///
/// Designed to be serializable to JSON or SQLite for crash-recovery
/// and observability. Daemon integration is out of scope for this
/// scaffold — see S2-AGENT-001 for step-level retry policy and
/// H3-ORCH-001 for orchestration integration.
pub const TaskRecord = struct {
    /// Unique task identifier (e.g. UUID or backlog ID).
    id: []const u8,
    /// Human-readable task name or title.
    name: []const u8,
    /// Current lifecycle status.
    status: TaskStatus = .pending,
    /// Scheduling priority.
    priority: TaskPriority = .normal,
    /// Total number of top-level retry attempts consumed.
    retries: u32 = 0,
    /// Maximum allowed retries before marking as failed.
    max_retries: u32 = 3,
    /// Total number of steps planned (0 if unknown/single-step).
    total_steps: u32 = 0,
    /// Index of the current step being executed.
    current_step: u32 = 0,
    /// ISO-8601 timestamp when the task was created.
    created_at: []const u8,
    /// ISO-8601 timestamp when execution started (null if pending).
    started_at: ?[]const u8 = null,
    /// ISO-8601 timestamp when the task reached a terminal state.
    finished_at: ?[]const u8 = null,
    /// ISO-8601 timestamp of the last status change.
    updated_at: ?[]const u8 = null,
    /// Optional error message for the most recent failure.
    last_error: ?[]const u8 = null,
    /// The agent or origin that created this task.
    origin: []const u8 = "unknown",

    /// Free all heap-allocated fields.
    pub fn deinit(self: *const TaskRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.created_at);
        if (self.started_at) |s| allocator.free(s);
        if (self.finished_at) |f| allocator.free(f);
        if (self.updated_at) |u| allocator.free(u);
        if (self.last_error) |e| allocator.free(e);
        if (!std.mem.eql(u8, self.origin, "unknown")) {
            allocator.free(self.origin);
        }
    }

    /// Whether retries are still available.
    pub fn canRetry(self: TaskRecord) bool {
        return self.retries < self.max_retries;
    }

    /// Progress as a fraction in [0, 1]. Returns null if total_steps is 0.
    pub fn progress(self: TaskRecord) ?f64 {
        if (self.total_steps == 0) return null;
        return @as(f64, @floatFromInt(self.current_step)) /
            @as(f64, @floatFromInt(self.total_steps));
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "TaskStatus toString roundtrip" {
    const cases = [_]struct { s: TaskStatus, str: []const u8 }{
        .{ .s = .pending, .str = "pending" },
        .{ .s = .running, .str = "running" },
        .{ .s = .completed, .str = "completed" },
        .{ .s = .failed, .str = "failed" },
        .{ .s = .cancelled, .str = "cancelled" },
        .{ .s = .blocked, .str = "blocked" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.str, c.s.toString());
    }
}

test "TaskStatus fromString valid" {
    try std.testing.expect(TaskStatus.fromString("pending").? == .pending);
    try std.testing.expect(TaskStatus.fromString("running").? == .running);
    try std.testing.expect(TaskStatus.fromString("completed").? == .completed);
    try std.testing.expect(TaskStatus.fromString("failed").? == .failed);
    try std.testing.expect(TaskStatus.fromString("cancelled").? == .cancelled);
    try std.testing.expect(TaskStatus.fromString("blocked").? == .blocked);
}

test "TaskStatus fromString invalid returns null" {
    try std.testing.expect(TaskStatus.fromString("bogus") == null);
    try std.testing.expect(TaskStatus.fromString("") == null);
    try std.testing.expect(TaskStatus.fromString("PENDING") == null);
}

test "TaskStatus isTerminal" {
    try std.testing.expect(!TaskStatus.pending.isTerminal());
    try std.testing.expect(!TaskStatus.running.isTerminal());
    try std.testing.expect(!TaskStatus.blocked.isTerminal());
    try std.testing.expect(TaskStatus.completed.isTerminal());
    try std.testing.expect(TaskStatus.failed.isTerminal());
    try std.testing.expect(TaskStatus.cancelled.isTerminal());
}

test "TaskPriority toString roundtrip" {
    try std.testing.expectEqualStrings("low", TaskPriority.low.toString());
    try std.testing.expectEqualStrings("normal", TaskPriority.normal.toString());
    try std.testing.expectEqualStrings("high", TaskPriority.high.toString());
    try std.testing.expectEqualStrings("critical", TaskPriority.critical.toString());
}

test "TaskPriority fromString valid" {
    try std.testing.expect(TaskPriority.fromString("low").? == .low);
    try std.testing.expect(TaskPriority.fromString("normal").? == .normal);
    try std.testing.expect(TaskPriority.fromString("high").? == .high);
    try std.testing.expect(TaskPriority.fromString("critical").? == .critical);
}

test "TaskPriority fromString invalid returns null" {
    try std.testing.expect(TaskPriority.fromString("bogus") == null);
    try std.testing.expect(TaskPriority.fromString("") == null);
}

test "TaskPriority toOrdinal ordering" {
    try std.testing.expect(TaskPriority.low.toOrdinal() < TaskPriority.normal.toOrdinal());
    try std.testing.expect(TaskPriority.normal.toOrdinal() < TaskPriority.high.toOrdinal());
    try std.testing.expect(TaskPriority.high.toOrdinal() < TaskPriority.critical.toOrdinal());
}

test "StepRecord defaults" {
    const step = StepRecord{
        .index = 0,
        .label = "initialize",
    };
    try std.testing.expect(step.status == .pending);
    try std.testing.expectEqual(@as(u32, 0), step.retries);
    try std.testing.expect(step.started_at == null);
    try std.testing.expect(step.finished_at == null);
    try std.testing.expect(step.error_msg == null);
}

test "StepRecord with explicit fields" {
    const step = StepRecord{
        .index = 2,
        .label = "fetch data",
        .status = .running,
        .retries = 1,
        .started_at = "2026-02-22T10:00:00Z",
        .finished_at = null,
        .error_msg = null,
    };
    try std.testing.expectEqual(@as(u32, 2), step.index);
    try std.testing.expectEqualStrings("fetch data", step.label);
    try std.testing.expect(step.status == .running);
    try std.testing.expectEqual(@as(u32, 1), step.retries);
    try std.testing.expectEqualStrings("2026-02-22T10:00:00Z", step.started_at.?);
}

test "TaskRecord defaults" {
    const task = TaskRecord{
        .id = "task-001",
        .name = "test task",
        .created_at = "2026-02-22T00:00:00Z",
    };
    try std.testing.expect(task.status == .pending);
    try std.testing.expect(task.priority == .normal);
    try std.testing.expectEqual(@as(u32, 0), task.retries);
    try std.testing.expectEqual(@as(u32, 3), task.max_retries);
    try std.testing.expectEqual(@as(u32, 0), task.total_steps);
    try std.testing.expectEqual(@as(u32, 0), task.current_step);
    try std.testing.expect(task.started_at == null);
    try std.testing.expect(task.finished_at == null);
    try std.testing.expect(task.updated_at == null);
    try std.testing.expect(task.last_error == null);
    try std.testing.expectEqualStrings("unknown", task.origin);
}

test "TaskRecord with explicit fields" {
    const task = TaskRecord{
        .id = "task-042",
        .name = "deploy service",
        .status = .running,
        .priority = .high,
        .retries = 1,
        .max_retries = 5,
        .total_steps = 4,
        .current_step = 2,
        .created_at = "2026-02-22T08:00:00Z",
        .started_at = "2026-02-22T08:01:00Z",
        .updated_at = "2026-02-22T08:05:00Z",
        .origin = "planner",
    };
    try std.testing.expect(task.status == .running);
    try std.testing.expect(task.priority == .high);
    try std.testing.expectEqual(@as(u32, 1), task.retries);
    try std.testing.expectEqual(@as(u32, 5), task.max_retries);
    try std.testing.expectEqual(@as(u32, 4), task.total_steps);
    try std.testing.expectEqual(@as(u32, 2), task.current_step);
    try std.testing.expectEqualStrings("planner", task.origin);
    try std.testing.expectEqualStrings("2026-02-22T08:01:00Z", task.started_at.?);
    try std.testing.expectEqualStrings("2026-02-22T08:05:00Z", task.updated_at.?);
}

test "TaskRecord canRetry" {
    const fresh = TaskRecord{
        .id = "t1",
        .name = "n",
        .created_at = "2026-01-01T00:00:00Z",
        .retries = 0,
        .max_retries = 3,
    };
    try std.testing.expect(fresh.canRetry());

    const exhausted = TaskRecord{
        .id = "t2",
        .name = "n",
        .created_at = "2026-01-01T00:00:00Z",
        .retries = 3,
        .max_retries = 3,
    };
    try std.testing.expect(!exhausted.canRetry());

    const over = TaskRecord{
        .id = "t3",
        .name = "n",
        .created_at = "2026-01-01T00:00:00Z",
        .retries = 5,
        .max_retries = 3,
    };
    try std.testing.expect(!over.canRetry());
}

test "TaskRecord progress" {
    const no_steps = TaskRecord{
        .id = "t1",
        .name = "n",
        .created_at = "2026-01-01T00:00:00Z",
        .total_steps = 0,
    };
    try std.testing.expect(no_steps.progress() == null);

    const halfway = TaskRecord{
        .id = "t2",
        .name = "n",
        .created_at = "2026-01-01T00:00:00Z",
        .total_steps = 4,
        .current_step = 2,
    };
    try std.testing.expect(halfway.progress().? == 0.5);

    const done = TaskRecord{
        .id = "t3",
        .name = "n",
        .created_at = "2026-01-01T00:00:00Z",
        .total_steps = 3,
        .current_step = 3,
    };
    try std.testing.expect(done.progress().? == 1.0);

    const start = TaskRecord{
        .id = "t4",
        .name = "n",
        .created_at = "2026-01-01T00:00:00Z",
        .total_steps = 10,
        .current_step = 0,
    };
    try std.testing.expect(start.progress().? == 0.0);
}
