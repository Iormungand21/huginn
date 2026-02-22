//! Planner / executor / verifier orchestration pipeline.
//!
//! Provides pipeline types for decomposing daemon tasks into three stages:
//!   1. **Planner** — breaks a goal into a sequence of step plans.
//!   2. **Executor** — runs each planned step to produce output.
//!   3. **Verifier** — validates each step's output before accepting it.
//!
//! The pipeline is **disabled by default**: when `PipelineConfig.enabled`
//! is false the daemon bypasses orchestration entirely and dispatches
//! tasks through its existing direct path.  This ensures zero behavior
//! change unless a caller explicitly opts in.
//!
//! This module is a scaffold — the types and interfaces defined here will
//! be wired into daemon dispatch in a later stage.  See also:
//!   - `tasks.zig` for `TaskRecord`, `StepRecord`, `VerifierConfig`
//!   - `daemon.zig` for the supervised event loop

const std = @import("std");
const tasks = @import("tasks.zig");

// Re-export task types used by the pipeline so callers get a single import.
pub const TaskRecord = tasks.TaskRecord;
pub const StepRecord = tasks.StepRecord;
pub const TaskStatus = tasks.TaskStatus;
pub const StepRetryPolicy = tasks.StepRetryPolicy;
pub const VerifierConfig = tasks.VerifierConfig;
pub const VerifyResult = tasks.VerifyResult;
pub const VerifyOutcome = tasks.VerifyOutcome;

// ── Pipeline phase ───────────────────────────────────────────────

/// Current phase of the orchestration pipeline.
pub const PipelinePhase = enum {
    /// Pipeline has not started or is disabled.
    idle,
    /// Planner is decomposing the goal into steps.
    planning,
    /// Executor is running the current step.
    executing,
    /// Verifier is validating the current step's output.
    verifying,
    /// All steps completed and verified successfully.
    completed,
    /// Pipeline failed (exhausted retries or unrecoverable error).
    failed,

    pub fn toString(self: PipelinePhase) []const u8 {
        return switch (self) {
            .idle => "idle",
            .planning => "planning",
            .executing => "executing",
            .verifying => "verifying",
            .completed => "completed",
            .failed => "failed",
        };
    }

    pub fn fromString(s: []const u8) ?PipelinePhase {
        if (std.mem.eql(u8, s, "idle")) return .idle;
        if (std.mem.eql(u8, s, "planning")) return .planning;
        if (std.mem.eql(u8, s, "executing")) return .executing;
        if (std.mem.eql(u8, s, "verifying")) return .verifying;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return null;
    }

    /// Whether the pipeline has reached a terminal state.
    pub fn isTerminal(self: PipelinePhase) bool {
        return self == .completed or self == .failed;
    }

    /// Whether the pipeline is actively running (in a non-idle, non-terminal phase).
    pub fn isActive(self: PipelinePhase) bool {
        return switch (self) {
            .planning, .executing, .verifying => true,
            .idle, .completed, .failed => false,
        };
    }
};

// ── Step plan ────────────────────────────────────────────────────

/// A single planned step produced by the planner stage.
///
/// This is a *plan* (what to do), not a *record* (what happened).
/// Once executed, the result is tracked by a `StepRecord`.
pub const StepPlan = struct {
    /// Human-readable label describing the step.
    label: []const u8,
    /// Optional tool name to invoke (null for agent-decided steps).
    tool: ?[]const u8 = null,
    /// Optional serialized arguments for the tool.
    args: ?[]const u8 = null,

    pub fn deinit(self: *const StepPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.tool) |t| allocator.free(t);
        if (self.args) |a| allocator.free(a);
    }
};

// ── Stage results ────────────────────────────────────────────────

/// Output of the planner stage: an ordered sequence of step plans.
pub const PlannerResult = struct {
    /// Whether planning succeeded.
    ok: bool = true,
    /// Planned steps (empty on failure).
    steps: []const StepPlan = &.{},
    /// Optional context or rationale from the planner.
    context: ?[]const u8 = null,
    /// Error message if planning failed.
    error_msg: ?[]const u8 = null,

    pub const empty = PlannerResult{ .ok = true, .steps = &.{} };

    pub fn failure(msg: []const u8) PlannerResult {
        return .{ .ok = false, .error_msg = msg };
    }
};

/// Output of the executor stage for a single step.
pub const ExecuteResult = struct {
    /// Whether execution succeeded.
    ok: bool = true,
    /// Step output (may be empty on failure).
    output: []const u8 = "",
    /// Error message if execution failed.
    error_msg: ?[]const u8 = null,

    pub fn success(output: []const u8) ExecuteResult {
        return .{ .ok = true, .output = output };
    }

    pub fn failure(msg: []const u8) ExecuteResult {
        return .{ .ok = false, .error_msg = msg };
    }
};

// ── Stage function signatures ────────────────────────────────────

/// Planner hook: given a goal string, produce a plan (list of steps).
pub const PlannerFn = *const fn (goal: []const u8) PlannerResult;

/// Executor hook: given a step plan, execute it and return the result.
pub const ExecutorFn = *const fn (step: *const StepPlan) ExecuteResult;

// Verifier hook reuses `VerifierHookFn` from tasks.zig (via VerifierConfig).

// ── Pipeline config ──────────────────────────────────────────────

/// Master configuration for the orchestration pipeline.
///
/// When `enabled` is false (the default), the daemon skips orchestration
/// and dispatches tasks through the existing direct path — ensuring
/// zero behavior change for callers that don't opt in.
pub const PipelineConfig = struct {
    /// Whether the pipeline is active.  Default: false.
    enabled: bool = false,
    /// Optional planner stage hook.
    planner: ?PlannerFn = null,
    /// Optional executor stage hook.
    executor: ?ExecutorFn = null,
    /// Verifier config (disabled by default — reuses tasks.zig VerifierConfig).
    verifier: VerifierConfig = VerifierConfig.disabled,
    /// Step-level retry policy applied when verifier fails.
    retry_policy: StepRetryPolicy = .{},

    /// A fully disabled pipeline config (the default).
    pub const disabled = PipelineConfig{};

    /// Whether the pipeline is ready to run (enabled with at least planner + executor).
    pub fn isReady(self: PipelineConfig) bool {
        return self.enabled and self.planner != null and self.executor != null;
    }
};

// ── Pipeline state ───────────────────────────────────────────────

/// Runtime state of a single pipeline execution.
///
/// Tracks which phase is active, how many steps have been completed,
/// and any error information.  Designed to be persisted alongside
/// the parent `TaskRecord` for crash recovery.
pub const PipelineState = struct {
    /// Current phase.
    phase: PipelinePhase = .idle,
    /// Goal string that initiated this pipeline run.
    goal: []const u8 = "",
    /// Total planned steps (set after planning completes).
    steps_total: u32 = 0,
    /// Steps successfully completed (verified or skipped).
    steps_completed: u32 = 0,
    /// Index of the step currently being executed/verified.
    current_step: u32 = 0,
    /// Cumulative retry count across all steps.
    total_retries: u32 = 0,
    /// Error message from the most recent failure (null if none).
    last_error: ?[]const u8 = null,

    /// Create a new pipeline state for the given goal.
    pub fn initWithGoal(goal: []const u8) PipelineState {
        return .{ .phase = .idle, .goal = goal };
    }

    /// Progress as a fraction in [0, 1].  Returns null if steps_total is 0.
    pub fn progress(self: PipelineState) ?f64 {
        if (self.steps_total == 0) return null;
        return @as(f64, @floatFromInt(self.steps_completed)) /
            @as(f64, @floatFromInt(self.steps_total));
    }

    /// Whether the pipeline has finished (successfully or not).
    pub fn isDone(self: PipelineState) bool {
        return self.phase.isTerminal();
    }

    /// Transition to the planning phase.
    pub fn beginPlanning(self: *PipelineState) void {
        self.phase = .planning;
    }

    /// Record that planning produced N steps and transition to executing.
    pub fn planReady(self: *PipelineState, n_steps: u32) void {
        self.steps_total = n_steps;
        self.current_step = 0;
        self.steps_completed = 0;
        self.phase = if (n_steps > 0) .executing else .completed;
    }

    /// Transition the current step to the verifying phase.
    pub fn beginVerifying(self: *PipelineState) void {
        self.phase = .verifying;
    }

    /// Mark the current step as verified and advance.
    pub fn stepPassed(self: *PipelineState) void {
        self.steps_completed += 1;
        self.current_step += 1;
        if (self.steps_completed >= self.steps_total) {
            self.phase = .completed;
        } else {
            self.phase = .executing;
        }
    }

    /// Record a step retry.
    pub fn stepRetried(self: *PipelineState) void {
        self.total_retries += 1;
        self.phase = .executing;
    }

    /// Mark the pipeline as failed with an error message.
    pub fn fail(self: *PipelineState, msg: []const u8) void {
        self.phase = .failed;
        self.last_error = msg;
    }
};

// ── Tests ────────────────────────────────────────────────────────

test "PipelinePhase toString roundtrip" {
    const cases = [_]struct { p: PipelinePhase, s: []const u8 }{
        .{ .p = .idle, .s = "idle" },
        .{ .p = .planning, .s = "planning" },
        .{ .p = .executing, .s = "executing" },
        .{ .p = .verifying, .s = "verifying" },
        .{ .p = .completed, .s = "completed" },
        .{ .p = .failed, .s = "failed" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.s, c.p.toString());
        try std.testing.expect(PipelinePhase.fromString(c.s).? == c.p);
    }
}

test "PipelinePhase fromString invalid returns null" {
    try std.testing.expect(PipelinePhase.fromString("bogus") == null);
    try std.testing.expect(PipelinePhase.fromString("") == null);
}

test "PipelinePhase isTerminal" {
    try std.testing.expect(!PipelinePhase.idle.isTerminal());
    try std.testing.expect(!PipelinePhase.planning.isTerminal());
    try std.testing.expect(!PipelinePhase.executing.isTerminal());
    try std.testing.expect(!PipelinePhase.verifying.isTerminal());
    try std.testing.expect(PipelinePhase.completed.isTerminal());
    try std.testing.expect(PipelinePhase.failed.isTerminal());
}

test "PipelinePhase isActive" {
    try std.testing.expect(!PipelinePhase.idle.isActive());
    try std.testing.expect(PipelinePhase.planning.isActive());
    try std.testing.expect(PipelinePhase.executing.isActive());
    try std.testing.expect(PipelinePhase.verifying.isActive());
    try std.testing.expect(!PipelinePhase.completed.isActive());
    try std.testing.expect(!PipelinePhase.failed.isActive());
}

test "StepPlan defaults" {
    const plan = StepPlan{ .label = "fetch data" };
    try std.testing.expectEqualStrings("fetch data", plan.label);
    try std.testing.expect(plan.tool == null);
    try std.testing.expect(plan.args == null);
}

test "StepPlan with tool and args" {
    const plan = StepPlan{
        .label = "run shell",
        .tool = "shell",
        .args = "{\"cmd\": \"ls\"}",
    };
    try std.testing.expectEqualStrings("run shell", plan.label);
    try std.testing.expectEqualStrings("shell", plan.tool.?);
    try std.testing.expectEqualStrings("{\"cmd\": \"ls\"}", plan.args.?);
}

test "PlannerResult empty" {
    const r = PlannerResult.empty;
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(usize, 0), r.steps.len);
    try std.testing.expect(r.context == null);
    try std.testing.expect(r.error_msg == null);
}

test "PlannerResult failure" {
    const r = PlannerResult.failure("goal too vague");
    try std.testing.expect(!r.ok);
    try std.testing.expectEqualStrings("goal too vague", r.error_msg.?);
}

test "ExecuteResult success" {
    const r = ExecuteResult.success("file created");
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("file created", r.output);
    try std.testing.expect(r.error_msg == null);
}

test "ExecuteResult failure" {
    const r = ExecuteResult.failure("permission denied");
    try std.testing.expect(!r.ok);
    try std.testing.expectEqualStrings("permission denied", r.error_msg.?);
}

test "PipelineConfig disabled by default" {
    const cfg = PipelineConfig{};
    try std.testing.expect(!cfg.enabled);
    try std.testing.expect(cfg.planner == null);
    try std.testing.expect(cfg.executor == null);
    try std.testing.expect(!cfg.verifier.isActive());
    try std.testing.expect(!cfg.isReady());
}

test "PipelineConfig disabled sentinel" {
    const cfg = PipelineConfig.disabled;
    try std.testing.expect(!cfg.enabled);
    try std.testing.expect(!cfg.isReady());
}

fn stubPlanner(_: []const u8) PlannerResult {
    const steps = &[_]StepPlan{
        .{ .label = "step-1" },
        .{ .label = "step-2" },
    };
    return .{ .ok = true, .steps = steps };
}

fn stubExecutor(_: *const StepPlan) ExecuteResult {
    return ExecuteResult.success("done");
}

test "PipelineConfig isReady requires all hooks" {
    // enabled but no hooks
    const no_hooks = PipelineConfig{ .enabled = true };
    try std.testing.expect(!no_hooks.isReady());

    // planner only
    const planner_only = PipelineConfig{ .enabled = true, .planner = stubPlanner };
    try std.testing.expect(!planner_only.isReady());

    // executor only
    const executor_only = PipelineConfig{ .enabled = true, .executor = stubExecutor };
    try std.testing.expect(!executor_only.isReady());

    // both hooks, enabled
    const ready = PipelineConfig{
        .enabled = true,
        .planner = stubPlanner,
        .executor = stubExecutor,
    };
    try std.testing.expect(ready.isReady());

    // both hooks, but disabled
    const off = PipelineConfig{
        .enabled = false,
        .planner = stubPlanner,
        .executor = stubExecutor,
    };
    try std.testing.expect(!off.isReady());
}

test "PipelineState defaults" {
    const st = PipelineState{};
    try std.testing.expect(st.phase == .idle);
    try std.testing.expectEqual(@as(u32, 0), st.steps_total);
    try std.testing.expectEqual(@as(u32, 0), st.steps_completed);
    try std.testing.expectEqual(@as(u32, 0), st.current_step);
    try std.testing.expectEqual(@as(u32, 0), st.total_retries);
    try std.testing.expect(st.last_error == null);
    try std.testing.expect(!st.isDone());
    try std.testing.expect(st.progress() == null);
}

test "PipelineState initWithGoal" {
    const st = PipelineState.initWithGoal("deploy service");
    try std.testing.expectEqualStrings("deploy service", st.goal);
    try std.testing.expect(st.phase == .idle);
}

test "PipelineState happy path transitions" {
    var st = PipelineState.initWithGoal("test goal");

    // idle → planning
    st.beginPlanning();
    try std.testing.expect(st.phase == .planning);
    try std.testing.expect(st.phase.isActive());

    // planning → executing (3 steps)
    st.planReady(3);
    try std.testing.expect(st.phase == .executing);
    try std.testing.expectEqual(@as(u32, 3), st.steps_total);
    try std.testing.expectEqual(@as(u32, 0), st.current_step);

    // executing → verifying
    st.beginVerifying();
    try std.testing.expect(st.phase == .verifying);

    // step 0 passes → executing step 1
    st.stepPassed();
    try std.testing.expect(st.phase == .executing);
    try std.testing.expectEqual(@as(u32, 1), st.steps_completed);
    try std.testing.expectEqual(@as(u32, 1), st.current_step);

    // execute + verify step 1
    st.beginVerifying();
    st.stepPassed();
    try std.testing.expectEqual(@as(u32, 2), st.steps_completed);
    try std.testing.expect(st.phase == .executing);

    // execute + verify step 2 → completed
    st.beginVerifying();
    st.stepPassed();
    try std.testing.expect(st.phase == .completed);
    try std.testing.expect(st.isDone());
    try std.testing.expect(st.progress().? == 1.0);
}

test "PipelineState empty plan completes immediately" {
    var st = PipelineState.initWithGoal("noop");
    st.beginPlanning();
    st.planReady(0);
    try std.testing.expect(st.phase == .completed);
    try std.testing.expect(st.isDone());
}

test "PipelineState retry flow" {
    var st = PipelineState.initWithGoal("retry test");
    st.beginPlanning();
    st.planReady(2);

    // First step fails verification, gets retried
    st.beginVerifying();
    st.stepRetried();
    try std.testing.expect(st.phase == .executing);
    try std.testing.expectEqual(@as(u32, 1), st.total_retries);
    try std.testing.expectEqual(@as(u32, 0), st.steps_completed); // not advanced

    // Retry succeeds
    st.beginVerifying();
    st.stepPassed();
    try std.testing.expectEqual(@as(u32, 1), st.steps_completed);
}

test "PipelineState failure" {
    var st = PipelineState.initWithGoal("fail test");
    st.beginPlanning();
    st.planReady(2);
    st.beginVerifying();
    st.fail("step timed out");
    try std.testing.expect(st.phase == .failed);
    try std.testing.expect(st.isDone());
    try std.testing.expectEqualStrings("step timed out", st.last_error.?);
}

test "PipelineState progress tracking" {
    var st = PipelineState{};

    // No steps → null progress
    try std.testing.expect(st.progress() == null);

    st.steps_total = 4;
    st.steps_completed = 0;
    try std.testing.expect(st.progress().? == 0.0);

    st.steps_completed = 2;
    try std.testing.expect(st.progress().? == 0.5);

    st.steps_completed = 4;
    try std.testing.expect(st.progress().? == 1.0);
}

test "stub planner returns steps" {
    const result = stubPlanner("anything");
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 2), result.steps.len);
    try std.testing.expectEqualStrings("step-1", result.steps[0].label);
    try std.testing.expectEqualStrings("step-2", result.steps[1].label);
}

test "stub executor returns success" {
    const plan = StepPlan{ .label = "test" };
    const result = stubExecutor(&plan);
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("done", result.output);
}

test "PipelineConfig verifier integration" {
    // Pipeline with verifier enabled
    const cfg = PipelineConfig{
        .enabled = true,
        .planner = stubPlanner,
        .executor = stubExecutor,
        .verifier = .{
            .enabled = true,
            .hook = null, // no actual hook yet
            .retry_on_failure = true,
        },
    };
    try std.testing.expect(cfg.isReady());
    // Verifier has no hook so isActive is false (graceful degrade)
    try std.testing.expect(!cfg.verifier.isActive());

    // verify() on inactive verifier returns skipped
    const step = StepRecord{ .index = 0, .label = "test" };
    const vr = cfg.verifier.verify(&step, "output");
    try std.testing.expect(vr.outcome == .skipped);
}
