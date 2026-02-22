//! Persistent task state machine primitives for long-running work.
//!
//! Provides `TaskStatus`, `TaskPriority`, `StepRecord`, and `TaskRecord`
//! types for tracking multi-step autonomous tasks through their lifecycle.
//!
//! Also provides step-level retry policies (`StepRetryPolicy`,
//! `StepBackoffStrategy`) and a config-gated verifier hook
//! (`VerifierConfig`, `VerifyResult`) for post-step verification.
//!
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

// ── Step-level retry policy ────────────────────────────────────────

/// Backoff strategy for step-level retries.
pub const StepBackoffStrategy = enum {
    /// Fixed delay between every retry attempt.
    constant,
    /// Delay increases linearly: base * attempt.
    linear,
    /// Delay doubles each attempt: base * 2^attempt (capped by max_delay_ms).
    exponential,

    pub fn toString(self: StepBackoffStrategy) []const u8 {
        return switch (self) {
            .constant => "constant",
            .linear => "linear",
            .exponential => "exponential",
        };
    }

    pub fn fromString(s: []const u8) ?StepBackoffStrategy {
        if (std.mem.eql(u8, s, "constant")) return .constant;
        if (std.mem.eql(u8, s, "linear")) return .linear;
        if (std.mem.eql(u8, s, "exponential")) return .exponential;
        return null;
    }
};

/// Per-step retry policy controlling how and when a step is retried.
///
/// Defaults: up to 2 retries, exponential backoff starting at 500 ms,
/// capped at 30 s. Steps failing with non-retryable errors are not
/// retried regardless of this policy.
pub const StepRetryPolicy = struct {
    /// Maximum retries for this step (0 = no retries, run once only).
    max_retries: u32 = 2,
    /// Backoff strategy between retries.
    backoff: StepBackoffStrategy = .exponential,
    /// Base delay in milliseconds before the first retry.
    base_delay_ms: u64 = 500,
    /// Maximum delay cap in milliseconds.
    max_delay_ms: u64 = 30_000,

    /// A policy that never retries.
    pub const no_retry = StepRetryPolicy{ .max_retries = 0 };

    /// Compute the delay (in ms) for a given 0-based attempt index.
    ///
    /// Attempt 0 is the first retry (after the initial run).
    pub fn computeDelay(self: StepRetryPolicy, attempt: u32) u64 {
        const delay = switch (self.backoff) {
            .constant => self.base_delay_ms,
            .linear => self.base_delay_ms *| ((@as(u64, attempt) +| 1)),
            .exponential => blk: {
                if (attempt >= 63) break :blk self.max_delay_ms;
                break :blk self.base_delay_ms *| (@as(u64, 1) << @intCast(attempt));
            },
        };
        return @min(delay, self.max_delay_ms);
    }

    /// Whether the step should be retried given its current attempt count.
    pub fn shouldRetry(self: StepRetryPolicy, attempts_so_far: u32) bool {
        return attempts_so_far < self.max_retries;
    }
};

// ── Verifier hook ─────────────────────────────────────────────────

/// Outcome of a verification check on a completed step.
pub const VerifyOutcome = enum {
    /// Verification passed — step result is acceptable.
    passed,
    /// Verification failed — step should be retried or marked failed.
    failed,
    /// Verification was skipped (e.g. no verifier configured for this step).
    skipped,
    /// Verification encountered an error in the verifier itself.
    verifier_error,

    pub fn toString(self: VerifyOutcome) []const u8 {
        return switch (self) {
            .passed => "passed",
            .failed => "failed",
            .skipped => "skipped",
            .verifier_error => "verifier_error",
        };
    }

    pub fn fromString(s: []const u8) ?VerifyOutcome {
        if (std.mem.eql(u8, s, "passed")) return .passed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "skipped")) return .skipped;
        if (std.mem.eql(u8, s, "verifier_error")) return .verifier_error;
        return null;
    }

    /// Whether the outcome indicates the step succeeded.
    pub fn isAcceptable(self: VerifyOutcome) bool {
        return self == .passed or self == .skipped;
    }
};

/// Result returned by a verifier hook after inspecting a step's output.
pub const VerifyResult = struct {
    /// The verification outcome.
    outcome: VerifyOutcome,
    /// Optional human-readable message (e.g. why verification failed).
    message: ?[]const u8 = null,

    pub fn passed() VerifyResult {
        return .{ .outcome = .passed };
    }

    pub fn failed(msg: ?[]const u8) VerifyResult {
        return .{ .outcome = .failed, .message = msg };
    }

    pub fn skipped() VerifyResult {
        return .{ .outcome = .skipped };
    }

    pub fn verifierError(msg: ?[]const u8) VerifyResult {
        return .{ .outcome = .verifier_error, .message = msg };
    }
};

/// Function signature for a verifier hook.
///
/// Called after a step completes (before the result is accepted). Receives
/// the step record and the step's output string. Returns a `VerifyResult`
/// indicating whether the output is acceptable.
///
/// The hook pointer and context are opaque to the task system — the caller
/// is responsible for setting up the hook function and any context it needs.
pub const VerifierHookFn = *const fn (step: *const StepRecord, output: []const u8) VerifyResult;

/// Configuration for the optional verifier hook.
///
/// Disabled by default. When enabled, the hook function is called after
/// each step completes to validate the output before accepting it.
pub const VerifierConfig = struct {
    /// Whether the verifier hook is active. Default: false.
    enabled: bool = false,
    /// The verifier hook function (null when disabled).
    hook: ?VerifierHookFn = null,
    /// Whether to retry the step on verification failure (vs. failing immediately).
    retry_on_failure: bool = true,

    /// A disabled verifier config (the default).
    pub const disabled = VerifierConfig{};

    /// Whether this config is ready to verify (enabled and has a hook).
    pub fn isActive(self: VerifierConfig) bool {
        return self.enabled and self.hook != null;
    }

    /// Run the verifier hook on a step's output, or return skipped if inactive.
    pub fn verify(self: VerifierConfig, step: *const StepRecord, output: []const u8) VerifyResult {
        if (!self.isActive()) return VerifyResult.skipped();
        return self.hook.?(step, output);
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

// ── Step retry policy tests ───────────────────────────────────────

test "StepBackoffStrategy toString roundtrip" {
    try std.testing.expectEqualStrings("constant", StepBackoffStrategy.constant.toString());
    try std.testing.expectEqualStrings("linear", StepBackoffStrategy.linear.toString());
    try std.testing.expectEqualStrings("exponential", StepBackoffStrategy.exponential.toString());
}

test "StepBackoffStrategy fromString valid" {
    try std.testing.expect(StepBackoffStrategy.fromString("constant").? == .constant);
    try std.testing.expect(StepBackoffStrategy.fromString("linear").? == .linear);
    try std.testing.expect(StepBackoffStrategy.fromString("exponential").? == .exponential);
}

test "StepBackoffStrategy fromString invalid returns null" {
    try std.testing.expect(StepBackoffStrategy.fromString("bogus") == null);
    try std.testing.expect(StepBackoffStrategy.fromString("") == null);
}

test "StepRetryPolicy defaults" {
    const policy = StepRetryPolicy{};
    try std.testing.expectEqual(@as(u32, 2), policy.max_retries);
    try std.testing.expect(policy.backoff == .exponential);
    try std.testing.expectEqual(@as(u64, 500), policy.base_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), policy.max_delay_ms);
}

test "StepRetryPolicy no_retry sentinel" {
    const policy = StepRetryPolicy.no_retry;
    try std.testing.expectEqual(@as(u32, 0), policy.max_retries);
    try std.testing.expect(!policy.shouldRetry(0));
}

test "StepRetryPolicy shouldRetry" {
    const policy = StepRetryPolicy{ .max_retries = 3 };
    try std.testing.expect(policy.shouldRetry(0));
    try std.testing.expect(policy.shouldRetry(1));
    try std.testing.expect(policy.shouldRetry(2));
    try std.testing.expect(!policy.shouldRetry(3));
    try std.testing.expect(!policy.shouldRetry(4));
}

test "StepRetryPolicy computeDelay constant" {
    const policy = StepRetryPolicy{
        .backoff = .constant,
        .base_delay_ms = 1000,
        .max_delay_ms = 60_000,
    };
    try std.testing.expectEqual(@as(u64, 1000), policy.computeDelay(0));
    try std.testing.expectEqual(@as(u64, 1000), policy.computeDelay(1));
    try std.testing.expectEqual(@as(u64, 1000), policy.computeDelay(5));
}

test "StepRetryPolicy computeDelay linear" {
    const policy = StepRetryPolicy{
        .backoff = .linear,
        .base_delay_ms = 1000,
        .max_delay_ms = 10_000,
    };
    // attempt 0: 1000 * (0+1) = 1000
    try std.testing.expectEqual(@as(u64, 1000), policy.computeDelay(0));
    // attempt 1: 1000 * (1+1) = 2000
    try std.testing.expectEqual(@as(u64, 2000), policy.computeDelay(1));
    // attempt 2: 1000 * (2+1) = 3000
    try std.testing.expectEqual(@as(u64, 3000), policy.computeDelay(2));
    // attempt 9: 1000 * 10 = 10000 (at cap)
    try std.testing.expectEqual(@as(u64, 10_000), policy.computeDelay(9));
    // attempt 20: would be 21000 but capped at 10000
    try std.testing.expectEqual(@as(u64, 10_000), policy.computeDelay(20));
}

test "StepRetryPolicy computeDelay exponential" {
    const policy = StepRetryPolicy{
        .backoff = .exponential,
        .base_delay_ms = 500,
        .max_delay_ms = 30_000,
    };
    // attempt 0: 500 * 2^0 = 500
    try std.testing.expectEqual(@as(u64, 500), policy.computeDelay(0));
    // attempt 1: 500 * 2^1 = 1000
    try std.testing.expectEqual(@as(u64, 1000), policy.computeDelay(1));
    // attempt 2: 500 * 2^2 = 2000
    try std.testing.expectEqual(@as(u64, 2000), policy.computeDelay(2));
    // attempt 3: 500 * 2^3 = 4000
    try std.testing.expectEqual(@as(u64, 4000), policy.computeDelay(3));
    // attempt 6: 500 * 64 = 32000, capped at 30000
    try std.testing.expectEqual(@as(u64, 30_000), policy.computeDelay(6));
}

test "StepRetryPolicy computeDelay exponential overflow safety" {
    const policy = StepRetryPolicy{
        .backoff = .exponential,
        .base_delay_ms = 1000,
        .max_delay_ms = 60_000,
    };
    // Very high attempt should not overflow, should return max
    try std.testing.expectEqual(@as(u64, 60_000), policy.computeDelay(63));
    try std.testing.expectEqual(@as(u64, 60_000), policy.computeDelay(100));
}

// ── Verifier hook tests ───────────────────────────────────────────

test "VerifyOutcome toString roundtrip" {
    try std.testing.expectEqualStrings("passed", VerifyOutcome.passed.toString());
    try std.testing.expectEqualStrings("failed", VerifyOutcome.failed.toString());
    try std.testing.expectEqualStrings("skipped", VerifyOutcome.skipped.toString());
    try std.testing.expectEqualStrings("verifier_error", VerifyOutcome.verifier_error.toString());
}

test "VerifyOutcome fromString valid" {
    try std.testing.expect(VerifyOutcome.fromString("passed").? == .passed);
    try std.testing.expect(VerifyOutcome.fromString("failed").? == .failed);
    try std.testing.expect(VerifyOutcome.fromString("skipped").? == .skipped);
    try std.testing.expect(VerifyOutcome.fromString("verifier_error").? == .verifier_error);
}

test "VerifyOutcome fromString invalid returns null" {
    try std.testing.expect(VerifyOutcome.fromString("bogus") == null);
    try std.testing.expect(VerifyOutcome.fromString("") == null);
}

test "VerifyOutcome isAcceptable" {
    try std.testing.expect(VerifyOutcome.passed.isAcceptable());
    try std.testing.expect(VerifyOutcome.skipped.isAcceptable());
    try std.testing.expect(!VerifyOutcome.failed.isAcceptable());
    try std.testing.expect(!VerifyOutcome.verifier_error.isAcceptable());
}

test "VerifyResult constructors" {
    const p = VerifyResult.passed();
    try std.testing.expect(p.outcome == .passed);
    try std.testing.expect(p.message == null);

    const f = VerifyResult.failed("output mismatch");
    try std.testing.expect(f.outcome == .failed);
    try std.testing.expectEqualStrings("output mismatch", f.message.?);

    const s = VerifyResult.skipped();
    try std.testing.expect(s.outcome == .skipped);
    try std.testing.expect(s.message == null);

    const e = VerifyResult.verifierError("hook crashed");
    try std.testing.expect(e.outcome == .verifier_error);
    try std.testing.expectEqualStrings("hook crashed", e.message.?);
}

test "VerifierConfig disabled by default" {
    const cfg = VerifierConfig{};
    try std.testing.expect(!cfg.enabled);
    try std.testing.expect(cfg.hook == null);
    try std.testing.expect(!cfg.isActive());
}

test "VerifierConfig disabled sentinel" {
    const cfg = VerifierConfig.disabled;
    try std.testing.expect(!cfg.enabled);
    try std.testing.expect(!cfg.isActive());
}

test "VerifierConfig verify returns skipped when inactive" {
    const cfg = VerifierConfig.disabled;
    const step = StepRecord{ .index = 0, .label = "test" };
    const result = cfg.verify(&step, "some output");
    try std.testing.expect(result.outcome == .skipped);
}

fn testPassingHook(_: *const StepRecord, _: []const u8) VerifyResult {
    return VerifyResult.passed();
}

fn testFailingHook(_: *const StepRecord, _: []const u8) VerifyResult {
    return VerifyResult.failed("bad output");
}

test "VerifierConfig verify calls hook when active" {
    const cfg = VerifierConfig{
        .enabled = true,
        .hook = testPassingHook,
    };
    try std.testing.expect(cfg.isActive());

    const step = StepRecord{ .index = 0, .label = "check" };
    const result = cfg.verify(&step, "output");
    try std.testing.expect(result.outcome == .passed);
}

test "VerifierConfig verify propagates hook failure" {
    const cfg = VerifierConfig{
        .enabled = true,
        .hook = testFailingHook,
    };
    const step = StepRecord{ .index = 1, .label = "validate" };
    const result = cfg.verify(&step, "wrong output");
    try std.testing.expect(result.outcome == .failed);
    try std.testing.expectEqualStrings("bad output", result.message.?);
}

test "VerifierConfig enabled but no hook is not active" {
    const cfg = VerifierConfig{
        .enabled = true,
        .hook = null,
    };
    try std.testing.expect(!cfg.isActive());
    // verify should still return skipped
    const step = StepRecord{ .index = 0, .label = "test" };
    const result = cfg.verify(&step, "output");
    try std.testing.expect(result.outcome == .skipped);
}
