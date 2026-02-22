//! Tool reliability wrapper — retries, timeouts, and health tracking.
//!
//! Provides `ToolPolicy` (per-tool retry/timeout configuration), `ToolHealth`
//! (runtime health state tracking), and `reliableExecute` (a wrapper that
//! applies the policy around any `Tool.execute` call).
//!
//! ## Usage
//!
//! ```zig
//! const policy = ToolPolicy{
//!     .max_retries = 3,
//!     .timeout_ns = 30 * std.time.ns_per_s,
//!     .backoff = .{ .base_ns = 100 * std.time.ns_per_ms },
//! };
//! var health = ToolHealth{};
//! const result = try reliability.reliableExecute(
//!     allocator, tool, args, policy, &health,
//! );
//! ```
//!
//! This module is a skeleton for incremental adoption. Individual tools can
//! opt in to reliability wrapping without requiring changes to tools that
//! don't need it.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

// ── ToolPolicy ──────────────────────────────────────────────────────

/// Per-tool retry and timeout configuration.
///
/// Sensible defaults: no retries, 60 s timeout, no backoff.
/// Tools that interact with external services (HTTP, hardware I/O) should
/// override with higher retry counts and appropriate backoff.
pub const ToolPolicy = struct {
    /// Maximum number of retry attempts after the initial call (0 = no retries).
    max_retries: u32 = 0,

    /// Per-attempt timeout in nanoseconds (0 = no timeout).
    timeout_ns: u64 = 60 * std.time.ns_per_s,

    /// Backoff configuration between retries.
    backoff: BackoffConfig = .{},

    /// Whether to retry on timeout specifically.
    retry_on_timeout: bool = true,

    /// Set of error categories that should trigger a retry.
    retryable_errors: RetryableErrors = .{},
};

/// Backoff strategy configuration for inter-retry delays.
pub const BackoffConfig = struct {
    /// Base delay in nanoseconds before first retry.
    base_ns: u64 = 100 * std.time.ns_per_ms,

    /// Multiplicative factor per retry (fixed-point: 1000 = 1.0x, 2000 = 2.0x).
    /// Default 2000 = exponential backoff with 2x multiplier.
    multiplier_fp: u32 = 2000,

    /// Maximum delay cap in nanoseconds.
    max_ns: u64 = 10 * std.time.ns_per_s,

    /// Compute the delay for a given attempt (0-indexed).
    pub fn delayForAttempt(self: BackoffConfig, attempt: u32) u64 {
        var delay = self.base_ns;
        for (0..attempt) |_| {
            delay = delay * self.multiplier_fp / 1000;
            if (delay >= self.max_ns) return self.max_ns;
        }
        return @min(delay, self.max_ns);
    }
};

/// Categories of errors that can be retried.
pub const RetryableErrors = struct {
    /// Retry on transient network/connection failures.
    network: bool = true,
    /// Retry on timeout (overridden by ToolPolicy.retry_on_timeout).
    timeout: bool = true,
    /// Retry on tool-reported transient errors (ToolResult.success == false
    /// with an error message containing "transient" or "retry").
    tool_transient: bool = true,
};

// ── ToolHealth ──────────────────────────────────────────────────────

/// Runtime health state for a single tool.
///
/// Tracks consecutive successes/failures and exposes a simple health
/// classification. This is the foundation for future circuit-breaker
/// logic (S2-TOOL-001).
pub const ToolHealth = struct {
    /// Total successful executions.
    total_successes: u64 = 0,

    /// Total failed executions (after all retries exhausted).
    total_failures: u64 = 0,

    /// Consecutive failures since last success.
    consecutive_failures: u32 = 0,

    /// Consecutive successes since last failure.
    consecutive_successes: u32 = 0,

    /// Timestamp (ns since boot) of last successful execution.
    last_success_ns: ?i128 = null,

    /// Timestamp (ns since boot) of last failed execution.
    last_failure_ns: ?i128 = null,

    /// Current health status.
    status: Status = .healthy,

    pub const Status = enum {
        /// Tool is operating normally.
        healthy,
        /// Tool has recent failures but is still usable.
        degraded,
        /// Tool has too many consecutive failures; callers should
        /// consider fallback behavior. (Circuit-breaker open state
        /// will be added in S2-TOOL-001.)
        unhealthy,
    };

    /// Threshold of consecutive failures before marking unhealthy.
    const unhealthy_threshold: u32 = 5;
    /// Threshold of consecutive failures before marking degraded.
    const degraded_threshold: u32 = 2;

    /// Record a successful execution.
    pub fn recordSuccess(self: *ToolHealth) void {
        self.total_successes += 1;
        self.consecutive_successes += 1;
        self.consecutive_failures = 0;
        self.last_success_ns = std.time.nanoTimestamp();
        self.status = .healthy;
    }

    /// Record a failed execution.
    pub fn recordFailure(self: *ToolHealth) void {
        self.total_failures += 1;
        self.consecutive_failures += 1;
        self.consecutive_successes = 0;
        self.last_failure_ns = std.time.nanoTimestamp();
        self.updateStatus();
    }

    fn updateStatus(self: *ToolHealth) void {
        if (self.consecutive_failures >= unhealthy_threshold) {
            self.status = .unhealthy;
        } else if (self.consecutive_failures >= degraded_threshold) {
            self.status = .degraded;
        }
        // Don't downgrade from unhealthy without a success
    }

    /// Reset health state (e.g., after manual recovery).
    pub fn reset(self: *ToolHealth) void {
        self.* = .{};
    }
};

// ── Wrapper API ─────────────────────────────────────────────────────

/// Outcome of a reliable execution attempt, including retry metadata.
pub const ReliableResult = struct {
    /// The final tool result (from the last attempt).
    result: ToolResult,
    /// Number of attempts made (1 = no retries needed).
    attempts: u32,
    /// Whether the result came after one or more retries.
    retried: bool,
};

/// Execute a tool with the given policy, applying retries and updating health.
///
/// This is the primary entry point for reliability-wrapped tool calls.
/// It delegates to the tool's normal `execute` and layers retry/backoff
/// logic on top.
///
/// Timeout enforcement is a TODO — the current skeleton performs retries
/// but does not yet cancel long-running tool executions. Per-attempt
/// timeout will be wired in when async/threaded cancellation is available.
pub fn reliableExecute(
    allocator: std.mem.Allocator,
    tool: Tool,
    args: JsonObjectMap,
    policy: ToolPolicy,
    health: ?*ToolHealth,
) !ReliableResult {
    const max_attempts: u32 = 1 + policy.max_retries;
    var attempt: u32 = 0;

    while (attempt < max_attempts) : (attempt += 1) {
        // Backoff delay before retry (not on first attempt)
        if (attempt > 0) {
            const delay = policy.backoff.delayForAttempt(attempt - 1);
            if (delay > 0) {
                std.time.sleep(delay);
            }
        }

        const result = tool.execute(allocator, args) catch |err| {
            // Tool returned a Zig error — treat as infrastructure failure.
            if (health) |h| h.recordFailure();
            if (attempt + 1 < max_attempts and isRetryableError(err)) {
                continue;
            }
            return err;
        };

        if (result.success) {
            if (health) |h| h.recordSuccess();
            return .{
                .result = result,
                .attempts = attempt + 1,
                .retried = attempt > 0,
            };
        }

        // Tool returned a ToolResult with success=false.
        // Check if this is a retryable transient error.
        if (attempt + 1 < max_attempts and policy.retryable_errors.tool_transient) {
            if (isTransientToolError(result)) {
                // Free the failed result before retrying (if heap-allocated)
                // Note: callers using static strings won't need freeing,
                // but we can't distinguish here — skip free for safety.
                continue;
            }
        }

        // Non-retryable failure or retries exhausted.
        if (health) |h| h.recordFailure();
        return .{
            .result = result,
            .attempts = attempt + 1,
            .retried = attempt > 0,
        };
    }

    // Should not reach here, but handle defensively.
    if (health) |h| h.recordFailure();
    return .{
        .result = ToolResult.fail("reliability: max retries exhausted"),
        .attempts = max_attempts,
        .retried = true,
    };
}

/// Check if a Zig error is retryable (connection/transient infrastructure errors).
fn isRetryableError(err: anyerror) bool {
    // Common std.http / std.net error categories that are transient.
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.BrokenPipe,
        error.NetworkUnreachable,
        error.HostUnreachable,
        => true,
        else => false,
    };
}

/// Check if a failed ToolResult indicates a transient error worth retrying.
fn isTransientToolError(result: ToolResult) bool {
    const msg = result.error_msg orelse return false;
    // Simple heuristic: look for keywords that suggest transience.
    if (std.ascii.indexOfIgnoreCase(msg, "timeout") != null) return true;
    if (std.ascii.indexOfIgnoreCase(msg, "transient") != null) return true;
    if (std.ascii.indexOfIgnoreCase(msg, "temporary") != null) return true;
    if (std.ascii.indexOfIgnoreCase(msg, "retry") != null) return true;
    if (std.ascii.indexOfIgnoreCase(msg, "connection") != null) return true;
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

test "ToolPolicy default values" {
    const p = ToolPolicy{};
    try std.testing.expectEqual(@as(u32, 0), p.max_retries);
    try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), p.timeout_ns);
    try std.testing.expect(p.retry_on_timeout);
}

test "BackoffConfig.delayForAttempt exponential" {
    const cfg = BackoffConfig{
        .base_ns = 1000,
        .multiplier_fp = 2000, // 2x
        .max_ns = 100_000,
    };
    // attempt 0: base = 1000
    try std.testing.expectEqual(@as(u64, 1000), cfg.delayForAttempt(0));
    // attempt 1: 1000 * 2 = 2000
    try std.testing.expectEqual(@as(u64, 2000), cfg.delayForAttempt(1));
    // attempt 2: 1000 * 2 * 2 = 4000
    try std.testing.expectEqual(@as(u64, 4000), cfg.delayForAttempt(2));
}

test "BackoffConfig.delayForAttempt caps at max" {
    const cfg = BackoffConfig{
        .base_ns = 1000,
        .multiplier_fp = 2000,
        .max_ns = 3000,
    };
    // attempt 0: 1000 (under cap)
    try std.testing.expectEqual(@as(u64, 1000), cfg.delayForAttempt(0));
    // attempt 1: 2000 (under cap)
    try std.testing.expectEqual(@as(u64, 2000), cfg.delayForAttempt(1));
    // attempt 2: would be 4000, capped to 3000
    try std.testing.expectEqual(@as(u64, 3000), cfg.delayForAttempt(2));
    // attempt 10: still capped
    try std.testing.expectEqual(@as(u64, 3000), cfg.delayForAttempt(10));
}

test "ToolHealth starts healthy" {
    const h = ToolHealth{};
    try std.testing.expectEqual(ToolHealth.Status.healthy, h.status);
    try std.testing.expectEqual(@as(u64, 0), h.total_successes);
    try std.testing.expectEqual(@as(u64, 0), h.total_failures);
}

test "ToolHealth.recordSuccess updates counters" {
    var h = ToolHealth{};
    h.recordSuccess();
    try std.testing.expectEqual(@as(u64, 1), h.total_successes);
    try std.testing.expectEqual(@as(u32, 1), h.consecutive_successes);
    try std.testing.expectEqual(@as(u32, 0), h.consecutive_failures);
    try std.testing.expectEqual(ToolHealth.Status.healthy, h.status);
    try std.testing.expect(h.last_success_ns != null);
}

test "ToolHealth.recordFailure transitions to degraded then unhealthy" {
    var h = ToolHealth{};
    // First failure — still healthy
    h.recordFailure();
    try std.testing.expectEqual(ToolHealth.Status.healthy, h.status);
    // Second failure — degraded
    h.recordFailure();
    try std.testing.expectEqual(ToolHealth.Status.degraded, h.status);
    // Three more failures (total 5) — unhealthy
    h.recordFailure();
    h.recordFailure();
    h.recordFailure();
    try std.testing.expectEqual(ToolHealth.Status.unhealthy, h.status);
    try std.testing.expectEqual(@as(u32, 5), h.consecutive_failures);
}

test "ToolHealth.recordSuccess resets from unhealthy to healthy" {
    var h = ToolHealth{};
    for (0..5) |_| h.recordFailure();
    try std.testing.expectEqual(ToolHealth.Status.unhealthy, h.status);
    h.recordSuccess();
    try std.testing.expectEqual(ToolHealth.Status.healthy, h.status);
    try std.testing.expectEqual(@as(u32, 0), h.consecutive_failures);
}

test "ToolHealth.reset clears all state" {
    var h = ToolHealth{};
    h.recordFailure();
    h.recordFailure();
    h.recordSuccess();
    h.reset();
    try std.testing.expectEqual(@as(u64, 0), h.total_successes);
    try std.testing.expectEqual(@as(u64, 0), h.total_failures);
    try std.testing.expectEqual(ToolHealth.Status.healthy, h.status);
}

test "isTransientToolError detects transient keywords" {
    try std.testing.expect(isTransientToolError(ToolResult{
        .success = false,
        .output = "",
        .error_msg = "connection reset by peer",
    }));
    try std.testing.expect(isTransientToolError(ToolResult{
        .success = false,
        .output = "",
        .error_msg = "request Timeout after 30s",
    }));
    try std.testing.expect(!isTransientToolError(ToolResult{
        .success = false,
        .output = "",
        .error_msg = "permission denied",
    }));
    try std.testing.expect(!isTransientToolError(ToolResult{
        .success = false,
        .output = "",
        .error_msg = null,
    }));
}

test "reliableExecute succeeds on first attempt without retries" {
    // Create a mock tool that always succeeds
    const MockSuccess = struct {
        fn exec(_: *anyopaque, _: std.mem.Allocator, _: JsonObjectMap) anyerror!ToolResult {
            return ToolResult.ok("success");
        }
        fn n(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn d(_: *anyopaque) []const u8 {
            return "mock tool";
        }
        fn p(_: *anyopaque) []const u8 {
            return "{}";
        }
    };
    const vtable = Tool.VTable{
        .execute = &MockSuccess.exec,
        .name = &MockSuccess.n,
        .description = &MockSuccess.d,
        .parameters_json = &MockSuccess.p,
    };
    // ptr is unused by our mock, but must be non-null
    var dummy: u8 = 0;
    const mock_tool = Tool{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var health = ToolHealth{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    const outcome = try reliableExecute(
        std.testing.allocator,
        mock_tool,
        parsed.value.object,
        ToolPolicy{},
        &health,
    );

    try std.testing.expect(outcome.result.success);
    try std.testing.expectEqual(@as(u32, 1), outcome.attempts);
    try std.testing.expect(!outcome.retried);
    try std.testing.expectEqual(@as(u64, 1), health.total_successes);
}

test "reliableExecute retries on transient failure then succeeds" {
    // Mock tool that fails twice with transient error, then succeeds
    const MockRetry = struct {
        var call_count: u32 = 0;
        fn exec(_: *anyopaque, _: std.mem.Allocator, _: JsonObjectMap) anyerror!ToolResult {
            call_count += 1;
            if (call_count <= 2) {
                return ToolResult{ .success = false, .output = "", .error_msg = "connection timeout" };
            }
            return ToolResult.ok("recovered");
        }
        fn n(_: *anyopaque) []const u8 {
            return "mock_retry";
        }
        fn d(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn p(_: *anyopaque) []const u8 {
            return "{}";
        }
    };
    MockRetry.call_count = 0;
    const vtable = Tool.VTable{
        .execute = &MockRetry.exec,
        .name = &MockRetry.n,
        .description = &MockRetry.d,
        .parameters_json = &MockRetry.p,
    };
    var dummy: u8 = 0;
    const mock_tool = Tool{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var health = ToolHealth{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    const outcome = try reliableExecute(
        std.testing.allocator,
        mock_tool,
        parsed.value.object,
        ToolPolicy{
            .max_retries = 3,
            .backoff = .{ .base_ns = 1, .max_ns = 1 }, // minimal delay for tests
        },
        &health,
    );

    try std.testing.expect(outcome.result.success);
    try std.testing.expectEqual(@as(u32, 3), outcome.attempts);
    try std.testing.expect(outcome.retried);
    try std.testing.expectEqual(@as(u64, 1), health.total_successes);
}

test "reliableExecute gives up after max retries" {
    const MockAlwaysFail = struct {
        fn exec(_: *anyopaque, _: std.mem.Allocator, _: JsonObjectMap) anyerror!ToolResult {
            return ToolResult{ .success = false, .output = "", .error_msg = "transient error" };
        }
        fn n(_: *anyopaque) []const u8 {
            return "mock_fail";
        }
        fn d(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn p(_: *anyopaque) []const u8 {
            return "{}";
        }
    };
    const vtable = Tool.VTable{
        .execute = &MockAlwaysFail.exec,
        .name = &MockAlwaysFail.n,
        .description = &MockAlwaysFail.d,
        .parameters_json = &MockAlwaysFail.p,
    };
    var dummy: u8 = 0;
    const mock_tool = Tool{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var health = ToolHealth{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    const outcome = try reliableExecute(
        std.testing.allocator,
        mock_tool,
        parsed.value.object,
        ToolPolicy{
            .max_retries = 2,
            .backoff = .{ .base_ns = 1, .max_ns = 1 },
        },
        &health,
    );

    try std.testing.expect(!outcome.result.success);
    try std.testing.expectEqual(@as(u32, 3), outcome.attempts); // 1 + 2 retries
    try std.testing.expect(outcome.retried);
    try std.testing.expectEqual(@as(u64, 1), health.total_failures);
}

test "reliableExecute with null health tracker" {
    const MockSuccess = struct {
        fn exec(_: *anyopaque, _: std.mem.Allocator, _: JsonObjectMap) anyerror!ToolResult {
            return ToolResult.ok("ok");
        }
        fn n(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn d(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn p(_: *anyopaque) []const u8 {
            return "{}";
        }
    };
    const vtable = Tool.VTable{
        .execute = &MockSuccess.exec,
        .name = &MockSuccess.n,
        .description = &MockSuccess.d,
        .parameters_json = &MockSuccess.p,
    };
    var dummy: u8 = 0;
    const mock_tool = Tool{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    // Should work without a health tracker
    const outcome = try reliableExecute(
        std.testing.allocator,
        mock_tool,
        parsed.value.object,
        ToolPolicy{},
        null,
    );
    try std.testing.expect(outcome.result.success);
}
