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
/// classification. See `CircuitBreaker` for the circuit-breaker state
/// machine that builds on this health tracking.
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
        /// consider fallback behavior. See `CircuitBreaker` for
        /// circuit-breaker gating.
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

// ── Cache primitives ────────────────────────────────────────────────

/// A cache key combining tool name and an argument fingerprint.
///
/// The `args_hash` is a 64-bit hash of the serialised argument map,
/// allowing callers to compute it however they like (e.g. std.hash_map.hashString
/// over the JSON representation). Two calls with the same tool name and
/// args_hash are considered cache-equivalent.
pub const CacheKey = struct {
    tool_name: []const u8,
    args_hash: u64,

    pub fn eql(a: CacheKey, b: CacheKey) bool {
        return a.args_hash == b.args_hash and std.mem.eql(u8, a.tool_name, b.tool_name);
    }
};

/// A cached tool result with creation time and TTL.
pub const CacheEntry = struct {
    /// The cached result.
    result: ToolResult,
    /// Monotonic timestamp (ns) when the entry was created.
    created_ns: i128,
    /// Time-to-live in nanoseconds. 0 means never expires.
    ttl_ns: u64,

    /// Check whether this cache entry is still valid at the given timestamp.
    pub fn isValid(self: CacheEntry, now_ns: i128) bool {
        if (self.ttl_ns == 0) return true; // no expiry
        const age: i128 = now_ns - self.created_ns;
        if (age < 0) return true; // clock went backwards; treat as valid
        return @as(u128, @intCast(age)) < @as(u128, self.ttl_ns);
    }
};

/// Per-tool cache configuration.
pub const CacheConfig = struct {
    /// Whether caching is enabled for this tool.
    enabled: bool = false,
    /// Default TTL for cache entries in nanoseconds. 0 = no expiry.
    default_ttl_ns: u64 = 5 * std.time.ns_per_min,
    /// Maximum number of cached entries (0 = unlimited).
    max_entries: u32 = 64,
};

/// Simple in-memory cache store for tool results, keyed by CacheKey.
///
/// Uses a flat ArrayList for simplicity (cache sizes are expected to be
/// small — tens of entries per tool). A HashMap could replace this if
/// needed for larger caches.
pub const ToolCache = struct {
    const Entry = struct {
        key: CacheKey,
        entry: CacheEntry,
    };

    entries: std.ArrayList(Entry),
    config: CacheConfig,

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) ToolCache {
        return .{
            .entries = std.ArrayList(Entry).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *ToolCache) void {
        self.entries.deinit();
    }

    /// Look up a cache entry. Returns null if not found or expired.
    pub fn get(self: *const ToolCache, key: CacheKey) ?ToolResult {
        const now = std.time.nanoTimestamp();
        for (self.entries.items) |item| {
            if (CacheKey.eql(item.key, key)) {
                if (item.entry.isValid(now)) {
                    return item.entry.result;
                }
                return null; // expired
            }
        }
        return null;
    }

    /// Store a result in the cache. If the key already exists, it is replaced.
    /// If the cache is full, the oldest entry is evicted.
    pub fn put(self: *ToolCache, key: CacheKey, result: ToolResult) !void {
        const now = std.time.nanoTimestamp();
        const entry = CacheEntry{
            .result = result,
            .created_ns = now,
            .ttl_ns = self.config.default_ttl_ns,
        };

        // Replace existing entry for the same key
        for (self.entries.items, 0..) |item, i| {
            if (CacheKey.eql(item.key, key)) {
                self.entries.items[i].entry = entry;
                return;
            }
        }

        // Evict oldest if at capacity
        if (self.config.max_entries > 0 and self.entries.items.len >= self.config.max_entries) {
            _ = self.entries.orderedRemove(0);
        }

        try self.entries.append(.{ .key = key, .entry = entry });
    }

    /// Remove all entries from the cache.
    pub fn clear(self: *ToolCache) void {
        self.entries.clearRetainingCapacity();
    }

    /// Number of entries currently in the cache.
    pub fn count(self: *const ToolCache) usize {
        return self.entries.items.len;
    }
};

// ── Circuit breaker ─────────────────────────────────────────────────

/// Circuit breaker states following the standard pattern:
///
/// ```
///   closed ──(failures >= threshold)──► open
///     ▲                                   │
///     │                          (recovery_timeout_ns elapsed)
///     │                                   ▼
///     └────(probe succeeds)──── half_open
///                                   │
///                          (probe fails) ──► open
/// ```
pub const CircuitState = enum {
    /// Normal operation — calls are permitted.
    closed,
    /// Circuit is tripped — calls are rejected immediately.
    open,
    /// Recovery probe — a limited number of calls are allowed to test recovery.
    half_open,
};

/// Configuration for a circuit breaker.
pub const CircuitBreakerConfig = struct {
    /// Number of consecutive failures before the circuit opens.
    failure_threshold: u32 = 5,
    /// Time in nanoseconds before an open circuit transitions to half-open.
    recovery_timeout_ns: u64 = 30 * std.time.ns_per_s,
    /// Maximum probe calls allowed in the half-open state.
    half_open_max_probes: u32 = 1,
};

/// Circuit breaker state machine for a single tool.
///
/// Wraps around `ToolHealth` to add open/half-open gating. Use
/// `isCallPermitted()` before making a tool call, then call
/// `recordSuccess()` or `recordFailure()` with the outcome.
pub const CircuitBreaker = struct {
    state: CircuitState = .closed,
    config: CircuitBreakerConfig = .{},
    /// Timestamp (ns) when the circuit was last opened/tripped.
    opened_at_ns: i128 = 0,
    /// Number of probe calls made in the current half-open window.
    half_open_probes: u32 = 0,
    /// Consecutive failure count (local to breaker, independent of ToolHealth).
    consecutive_failures: u32 = 0,

    /// Check whether a call is permitted under the current circuit state.
    ///
    /// - `closed`: always permitted.
    /// - `open`: permitted only if the recovery timeout has elapsed
    ///   (transitions to `half_open` as a side-effect).
    /// - `half_open`: permitted if the probe count is below the limit.
    pub fn isCallPermitted(self: *CircuitBreaker) bool {
        return self.isCallPermittedAt(std.time.nanoTimestamp());
    }

    /// Testable version of `isCallPermitted` with an explicit timestamp.
    pub fn isCallPermittedAt(self: *CircuitBreaker, now_ns: i128) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                const elapsed = now_ns - self.opened_at_ns;
                if (elapsed < 0) return false; // clock skew — stay open
                if (@as(u128, @intCast(elapsed)) >= @as(u128, self.config.recovery_timeout_ns)) {
                    // Transition to half-open
                    self.state = .half_open;
                    self.half_open_probes = 0;
                    return self.isCallPermittedAt(now_ns);
                }
                return false;
            },
            .half_open => {
                if (self.half_open_probes < self.config.half_open_max_probes) {
                    self.half_open_probes += 1;
                    return true;
                }
                return false;
            },
        }
    }

    /// Record a successful call — closes the circuit.
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.consecutive_failures = 0;
        self.state = .closed;
        self.half_open_probes = 0;
    }

    /// Record a failed call — may trip the circuit open.
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.recordFailureAt(std.time.nanoTimestamp());
    }

    /// Testable version of `recordFailure` with an explicit timestamp.
    pub fn recordFailureAt(self: *CircuitBreaker, now_ns: i128) void {
        self.consecutive_failures += 1;
        switch (self.state) {
            .closed => {
                if (self.consecutive_failures >= self.config.failure_threshold) {
                    self.trip(now_ns);
                }
            },
            .half_open => {
                // Probe failed — re-open the circuit
                self.trip(now_ns);
            },
            .open => {
                // Already open; update the opened_at to extend the timeout
                self.opened_at_ns = now_ns;
            },
        }
    }

    /// Manually trip the circuit to the open state.
    pub fn trip(self: *CircuitBreaker, now_ns: i128) void {
        self.state = .open;
        self.opened_at_ns = now_ns;
        self.half_open_probes = 0;
    }

    /// Manually reset the circuit to the closed state.
    pub fn reset(self: *CircuitBreaker) void {
        self.* = .{ .config = self.config };
    }
};

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

// ── Cache tests ─────────────────────────────────────────────────────

test "CacheKey.eql matches same tool and hash" {
    const a = CacheKey{ .tool_name = "http_request", .args_hash = 12345 };
    const b = CacheKey{ .tool_name = "http_request", .args_hash = 12345 };
    try std.testing.expect(CacheKey.eql(a, b));
}

test "CacheKey.eql differs on hash" {
    const a = CacheKey{ .tool_name = "http_request", .args_hash = 12345 };
    const b = CacheKey{ .tool_name = "http_request", .args_hash = 99999 };
    try std.testing.expect(!CacheKey.eql(a, b));
}

test "CacheKey.eql differs on tool name" {
    const a = CacheKey{ .tool_name = "shell", .args_hash = 12345 };
    const b = CacheKey{ .tool_name = "git", .args_hash = 12345 };
    try std.testing.expect(!CacheKey.eql(a, b));
}

test "CacheEntry.isValid within TTL" {
    const now: i128 = 1_000_000_000;
    const entry = CacheEntry{
        .result = ToolResult.ok("cached"),
        .created_ns = now - 100,
        .ttl_ns = 1000,
    };
    try std.testing.expect(entry.isValid(now));
}

test "CacheEntry.isValid expired" {
    const now: i128 = 1_000_000_000;
    const entry = CacheEntry{
        .result = ToolResult.ok("stale"),
        .created_ns = now - 2000,
        .ttl_ns = 1000,
    };
    try std.testing.expect(!entry.isValid(now));
}

test "CacheEntry.isValid with zero TTL never expires" {
    const now: i128 = 1_000_000_000;
    const entry = CacheEntry{
        .result = ToolResult.ok("permanent"),
        .created_ns = 0,
        .ttl_ns = 0,
    };
    try std.testing.expect(entry.isValid(now));
}

test "CacheEntry.isValid with clock skew" {
    // created_ns in the future — treat as valid
    const entry = CacheEntry{
        .result = ToolResult.ok("future"),
        .created_ns = 2_000_000_000,
        .ttl_ns = 100,
    };
    try std.testing.expect(entry.isValid(1_000_000_000));
}

test "CacheConfig default values" {
    const cfg = CacheConfig{};
    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_min), cfg.default_ttl_ns);
    try std.testing.expectEqual(@as(u32, 64), cfg.max_entries);
}

test "ToolCache put and get" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 0, // never expires
        .max_entries = 10,
    });
    defer cache.deinit();

    const key = CacheKey{ .tool_name = "test", .args_hash = 42 };
    try cache.put(key, ToolResult.ok("hello"));

    const result = cache.get(key);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.success);
    try std.testing.expectEqualStrings("hello", result.?.output);
}

test "ToolCache get returns null for missing key" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 0,
        .max_entries = 10,
    });
    defer cache.deinit();

    const key = CacheKey{ .tool_name = "test", .args_hash = 999 };
    try std.testing.expect(cache.get(key) == null);
}

test "ToolCache put replaces existing entry" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 0,
        .max_entries = 10,
    });
    defer cache.deinit();

    const key = CacheKey{ .tool_name = "test", .args_hash = 1 };
    try cache.put(key, ToolResult.ok("first"));
    try cache.put(key, ToolResult.ok("second"));

    try std.testing.expectEqual(@as(usize, 1), cache.count());
    const result = cache.get(key).?;
    try std.testing.expectEqualStrings("second", result.output);
}

test "ToolCache evicts oldest when full" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 0,
        .max_entries = 2,
    });
    defer cache.deinit();

    const k1 = CacheKey{ .tool_name = "t", .args_hash = 1 };
    const k2 = CacheKey{ .tool_name = "t", .args_hash = 2 };
    const k3 = CacheKey{ .tool_name = "t", .args_hash = 3 };

    try cache.put(k1, ToolResult.ok("a"));
    try cache.put(k2, ToolResult.ok("b"));
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    // Adding a third should evict k1 (oldest)
    try cache.put(k3, ToolResult.ok("c"));
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(cache.get(k1) == null); // evicted
    try std.testing.expect(cache.get(k2) != null);
    try std.testing.expect(cache.get(k3) != null);
}

test "ToolCache clear removes all entries" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 0,
        .max_entries = 10,
    });
    defer cache.deinit();

    try cache.put(.{ .tool_name = "a", .args_hash = 1 }, ToolResult.ok("x"));
    try cache.put(.{ .tool_name = "b", .args_hash = 2 }, ToolResult.ok("y"));
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

// ── Circuit breaker tests ───────────────────────────────────────────

test "CircuitBreaker starts closed" {
    const cb = CircuitBreaker{};
    try std.testing.expectEqual(CircuitState.closed, cb.state);
    try std.testing.expectEqual(@as(u32, 0), cb.consecutive_failures);
}

test "CircuitBreakerConfig default values" {
    const cfg = CircuitBreakerConfig{};
    try std.testing.expectEqual(@as(u32, 5), cfg.failure_threshold);
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), cfg.recovery_timeout_ns);
    try std.testing.expectEqual(@as(u32, 1), cfg.half_open_max_probes);
}

test "CircuitBreaker closed permits calls" {
    var cb = CircuitBreaker{};
    try std.testing.expect(cb.isCallPermittedAt(1000));
    try std.testing.expect(cb.isCallPermittedAt(2000));
}

test "CircuitBreaker trips after failure threshold" {
    var cb = CircuitBreaker{ .config = .{ .failure_threshold = 3 } };
    const now: i128 = 1_000_000;

    cb.recordFailureAt(now);
    try std.testing.expectEqual(CircuitState.closed, cb.state);
    cb.recordFailureAt(now);
    try std.testing.expectEqual(CircuitState.closed, cb.state);
    cb.recordFailureAt(now); // 3rd failure — trips
    try std.testing.expectEqual(CircuitState.open, cb.state);
}

test "CircuitBreaker open rejects calls" {
    var cb = CircuitBreaker{ .config = .{
        .failure_threshold = 1,
        .recovery_timeout_ns = 1000,
    } };
    const trip_time: i128 = 1_000_000;
    cb.recordFailureAt(trip_time);
    try std.testing.expectEqual(CircuitState.open, cb.state);

    // Call shortly after tripping — should be rejected
    try std.testing.expect(!cb.isCallPermittedAt(trip_time + 500));
    try std.testing.expectEqual(CircuitState.open, cb.state);
}

test "CircuitBreaker open transitions to half_open after timeout" {
    var cb = CircuitBreaker{ .config = .{
        .failure_threshold = 1,
        .recovery_timeout_ns = 1000,
    } };
    const trip_time: i128 = 1_000_000;
    cb.recordFailureAt(trip_time);
    try std.testing.expectEqual(CircuitState.open, cb.state);

    // After recovery timeout — should transition to half_open and permit
    try std.testing.expect(cb.isCallPermittedAt(trip_time + 1000));
    try std.testing.expectEqual(CircuitState.half_open, cb.state);
}

test "CircuitBreaker half_open limits probes" {
    var cb = CircuitBreaker{ .config = .{
        .failure_threshold = 1,
        .recovery_timeout_ns = 1000,
        .half_open_max_probes = 2,
    } };
    const trip_time: i128 = 1_000_000;
    cb.recordFailureAt(trip_time);

    const probe_time = trip_time + 1000;
    // First two probes allowed
    try std.testing.expect(cb.isCallPermittedAt(probe_time));
    try std.testing.expect(cb.isCallPermittedAt(probe_time));
    // Third probe rejected
    try std.testing.expect(!cb.isCallPermittedAt(probe_time));
}

test "CircuitBreaker half_open success closes circuit" {
    var cb = CircuitBreaker{ .config = .{
        .failure_threshold = 1,
        .recovery_timeout_ns = 1000,
    } };
    const trip_time: i128 = 1_000_000;
    cb.recordFailureAt(trip_time);

    _ = cb.isCallPermittedAt(trip_time + 1000); // transitions to half_open
    try std.testing.expectEqual(CircuitState.half_open, cb.state);

    cb.recordSuccess();
    try std.testing.expectEqual(CircuitState.closed, cb.state);
    try std.testing.expectEqual(@as(u32, 0), cb.consecutive_failures);
}

test "CircuitBreaker half_open failure re-opens circuit" {
    var cb = CircuitBreaker{ .config = .{
        .failure_threshold = 1,
        .recovery_timeout_ns = 1000,
    } };
    const trip_time: i128 = 1_000_000;
    cb.recordFailureAt(trip_time);

    const probe_time = trip_time + 1000;
    _ = cb.isCallPermittedAt(probe_time); // transitions to half_open
    try std.testing.expectEqual(CircuitState.half_open, cb.state);

    cb.recordFailureAt(probe_time + 1); // probe fails — re-opens
    try std.testing.expectEqual(CircuitState.open, cb.state);
}

test "CircuitBreaker success resets consecutive failures" {
    var cb = CircuitBreaker{ .config = .{ .failure_threshold = 5 } };
    cb.recordFailureAt(1000);
    cb.recordFailureAt(2000);
    try std.testing.expectEqual(@as(u32, 2), cb.consecutive_failures);

    cb.recordSuccess();
    try std.testing.expectEqual(@as(u32, 0), cb.consecutive_failures);
    try std.testing.expectEqual(CircuitState.closed, cb.state);
}

test "CircuitBreaker manual trip" {
    var cb = CircuitBreaker{};
    try std.testing.expectEqual(CircuitState.closed, cb.state);

    cb.trip(5_000_000);
    try std.testing.expectEqual(CircuitState.open, cb.state);
    try std.testing.expectEqual(@as(i128, 5_000_000), cb.opened_at_ns);
}

test "CircuitBreaker reset clears state" {
    var cb = CircuitBreaker{ .config = .{ .failure_threshold = 1 } };
    cb.recordFailureAt(1000);
    try std.testing.expectEqual(CircuitState.open, cb.state);

    cb.reset();
    try std.testing.expectEqual(CircuitState.closed, cb.state);
    try std.testing.expectEqual(@as(u32, 0), cb.consecutive_failures);
    // Config is preserved
    try std.testing.expectEqual(@as(u32, 1), cb.config.failure_threshold);
}
