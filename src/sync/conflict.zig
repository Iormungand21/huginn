//! Conflict resolution policy for synced tasks and memories.
//!
//! When two nodes produce concurrent deltas for the same record, a
//! deterministic resolution policy picks the winner. The policy applies a
//! strict precedence chain so that every node independently reaches the
//! same decision without coordination:
//!
//!   1. **last_confirmed_at** — the record most recently confirmed by a
//!      user or authoritative process wins. This gives human oversight
//!      the highest weight.
//!   2. **confidence** — if confirmation timestamps are equal (or both
//!      absent), the record with a higher confidence score wins.
//!   3. **updated_at** — among equal-confidence records, the most
//!      recently modified value wins (last-writer-wins).
//!   4. **source_node** — if all else is equal, lexicographic node-ID
//!      comparison provides a deterministic tiebreaker that every node
//!      can compute independently.
//!
//! Callers may also select a single-rule policy (e.g. pure last-writer-wins)
//! through `resolveWith`.

const std = @import("std");
const types = @import("types.zig");

const NodeId = types.NodeId;
const Timestamp = types.Timestamp;
const SequenceNum = types.SequenceNum;

// ── Types ─────────────────────────────────────────────────────────

/// Which side of a conflict a record belongs to.
pub const Side = enum {
    local,
    remote,
};

/// Resolution strategy — selectable per-kind or per-workspace.
pub const ResolutionPolicy = enum {
    /// Full precedence chain: confirmed > confidence > updated > node.
    full_precedence,
    /// Highest last_confirmed_at wins, then node tiebreaker.
    last_confirmed_wins,
    /// Highest confidence wins, then node tiebreaker.
    highest_confidence,
    /// Most recent updated_at wins, then node tiebreaker.
    last_writer_wins,
    /// Lexicographic node-ID ordering (purely deterministic).
    source_priority,
};

/// Metadata snapshot of one side of a conflict.
pub const ConflictRecord = struct {
    /// Node that produced this version.
    source_node: NodeId,
    /// Wall-clock ms when the record was last modified.
    updated_at: Timestamp,
    /// Wall-clock ms when the record was last confirmed by a user or
    /// authoritative process. 0 means never confirmed.
    last_confirmed_at: Timestamp = 0,
    /// Confidence score in [0, 1]. Default 0 means unscored.
    confidence: f64 = 0.0,
    /// Causal sequence number from the source node.
    sequence: SequenceNum = 0,
};

/// Result of a conflict resolution decision.
pub const ConflictOutcome = struct {
    /// Which side won.
    winner: Side,
    /// Which rule broke the tie.
    decided_by: ResolutionPolicy,
};

// ── Single-rule helpers ───────────────────────────────────────────

/// Compare by last_confirmed_at. Returns null on tie.
pub fn compareConfirmed(local: ConflictRecord, remote: ConflictRecord) ?Side {
    if (local.last_confirmed_at > remote.last_confirmed_at) return .local;
    if (remote.last_confirmed_at > local.last_confirmed_at) return .remote;
    return null;
}

/// Compare by confidence. Returns null on tie.
pub fn compareConfidence(local: ConflictRecord, remote: ConflictRecord) ?Side {
    if (local.confidence > remote.confidence) return .local;
    if (remote.confidence > local.confidence) return .remote;
    return null;
}

/// Compare by updated_at. Returns null on tie.
pub fn compareUpdatedAt(local: ConflictRecord, remote: ConflictRecord) ?Side {
    if (local.updated_at > remote.updated_at) return .local;
    if (remote.updated_at > local.updated_at) return .remote;
    return null;
}

/// Deterministic tiebreaker: lexicographic node-ID ordering.
/// The lexicographically *smaller* node-ID wins (stable, arbitrary convention).
/// Returns .local if IDs are identical (should not happen in practice).
pub fn compareSourceNode(local: ConflictRecord, remote: ConflictRecord) Side {
    const order = std.mem.order(u8, local.source_node.id, remote.source_node.id);
    return switch (order) {
        .lt => .local,
        .gt => .remote,
        .eq => .local, // identical nodes — local by convention
    };
}

// ── Policy resolution ─────────────────────────────────────────────

/// Resolve a conflict using the full precedence chain:
/// confirmed -> confidence -> updated_at -> source_node.
pub fn resolve(local: ConflictRecord, remote: ConflictRecord) ConflictOutcome {
    return resolveWith(local, remote, .full_precedence);
}

/// Resolve a conflict using a specific policy.
pub fn resolveWith(local: ConflictRecord, remote: ConflictRecord, policy: ResolutionPolicy) ConflictOutcome {
    switch (policy) {
        .full_precedence => {
            if (compareConfirmed(local, remote)) |side| {
                return .{ .winner = side, .decided_by = .last_confirmed_wins };
            }
            if (compareConfidence(local, remote)) |side| {
                return .{ .winner = side, .decided_by = .highest_confidence };
            }
            if (compareUpdatedAt(local, remote)) |side| {
                return .{ .winner = side, .decided_by = .last_writer_wins };
            }
            return .{ .winner = compareSourceNode(local, remote), .decided_by = .source_priority };
        },
        .last_confirmed_wins => {
            if (compareConfirmed(local, remote)) |side| {
                return .{ .winner = side, .decided_by = .last_confirmed_wins };
            }
            return .{ .winner = compareSourceNode(local, remote), .decided_by = .source_priority };
        },
        .highest_confidence => {
            if (compareConfidence(local, remote)) |side| {
                return .{ .winner = side, .decided_by = .highest_confidence };
            }
            return .{ .winner = compareSourceNode(local, remote), .decided_by = .source_priority };
        },
        .last_writer_wins => {
            if (compareUpdatedAt(local, remote)) |side| {
                return .{ .winner = side, .decided_by = .last_writer_wins };
            }
            return .{ .winner = compareSourceNode(local, remote), .decided_by = .source_priority };
        },
        .source_priority => {
            return .{ .winner = compareSourceNode(local, remote), .decided_by = .source_priority };
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn localRecord(updated: Timestamp, confirmed: Timestamp, conf: f64, node: []const u8) ConflictRecord {
    return .{
        .source_node = .{ .id = node },
        .updated_at = updated,
        .last_confirmed_at = confirmed,
        .confidence = conf,
    };
}

fn remoteRecord(updated: Timestamp, confirmed: Timestamp, conf: f64, node: []const u8) ConflictRecord {
    return .{
        .source_node = .{ .id = node },
        .updated_at = updated,
        .last_confirmed_at = confirmed,
        .confidence = conf,
    };
}

// ── compareConfirmed tests ────────────────────────────────────────

test "compareConfirmed: local wins with higher confirmed timestamp" {
    const local = localRecord(100, 200, 0.5, "alpha");
    const remote = remoteRecord(100, 100, 0.5, "beta");
    try testing.expect(compareConfirmed(local, remote).? == .local);
}

test "compareConfirmed: remote wins with higher confirmed timestamp" {
    const local = localRecord(100, 100, 0.5, "alpha");
    const remote = remoteRecord(100, 300, 0.5, "beta");
    try testing.expect(compareConfirmed(local, remote).? == .remote);
}

test "compareConfirmed: tie returns null" {
    const local = localRecord(100, 200, 0.5, "alpha");
    const remote = remoteRecord(100, 200, 0.5, "beta");
    try testing.expect(compareConfirmed(local, remote) == null);
}

// ── compareConfidence tests ───────────────────────────────────────

test "compareConfidence: local wins with higher confidence" {
    const local = localRecord(100, 0, 0.9, "alpha");
    const remote = remoteRecord(100, 0, 0.5, "beta");
    try testing.expect(compareConfidence(local, remote).? == .local);
}

test "compareConfidence: remote wins with higher confidence" {
    const local = localRecord(100, 0, 0.3, "alpha");
    const remote = remoteRecord(100, 0, 0.8, "beta");
    try testing.expect(compareConfidence(local, remote).? == .remote);
}

test "compareConfidence: tie returns null" {
    const local = localRecord(100, 0, 0.7, "alpha");
    const remote = remoteRecord(100, 0, 0.7, "beta");
    try testing.expect(compareConfidence(local, remote) == null);
}

// ── compareUpdatedAt tests ────────────────────────────────────────

test "compareUpdatedAt: local wins with newer timestamp" {
    const local = localRecord(500, 0, 0.5, "alpha");
    const remote = remoteRecord(400, 0, 0.5, "beta");
    try testing.expect(compareUpdatedAt(local, remote).? == .local);
}

test "compareUpdatedAt: remote wins with newer timestamp" {
    const local = localRecord(300, 0, 0.5, "alpha");
    const remote = remoteRecord(600, 0, 0.5, "beta");
    try testing.expect(compareUpdatedAt(local, remote).? == .remote);
}

test "compareUpdatedAt: tie returns null" {
    const local = localRecord(500, 0, 0.5, "alpha");
    const remote = remoteRecord(500, 0, 0.5, "beta");
    try testing.expect(compareUpdatedAt(local, remote) == null);
}

// ── compareSourceNode tests ───────────────────────────────────────

test "compareSourceNode: lexicographically smaller node wins" {
    const local = localRecord(100, 0, 0.5, "alpha");
    const remote = remoteRecord(100, 0, 0.5, "beta");
    try testing.expect(compareSourceNode(local, remote) == .local);
}

test "compareSourceNode: remote wins when its ID is smaller" {
    const local = localRecord(100, 0, 0.5, "zebra");
    const remote = remoteRecord(100, 0, 0.5, "aardvark");
    try testing.expect(compareSourceNode(local, remote) == .remote);
}

test "compareSourceNode: identical IDs default to local" {
    const local = localRecord(100, 0, 0.5, "same");
    const remote = remoteRecord(100, 0, 0.5, "same");
    try testing.expect(compareSourceNode(local, remote) == .local);
}

// ── Full precedence chain tests ───────────────────────────────────

test "resolve: confirmed timestamp takes priority" {
    const local = localRecord(100, 500, 0.3, "zebra");
    const remote = remoteRecord(999, 200, 0.9, "alpha");
    const outcome = resolve(local, remote);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .last_confirmed_wins);
}

test "resolve: confidence breaks tie when confirmed equal" {
    const local = localRecord(100, 200, 0.9, "zebra");
    const remote = remoteRecord(100, 200, 0.5, "alpha");
    const outcome = resolve(local, remote);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .highest_confidence);
}

test "resolve: updated_at breaks tie when confirmed and confidence equal" {
    const local = localRecord(999, 200, 0.5, "zebra");
    const remote = remoteRecord(100, 200, 0.5, "alpha");
    const outcome = resolve(local, remote);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .last_writer_wins);
}

test "resolve: source_node is final tiebreaker" {
    const local = localRecord(100, 200, 0.5, "alpha");
    const remote = remoteRecord(100, 200, 0.5, "beta");
    const outcome = resolve(local, remote);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .source_priority);
}

test "resolve: remote wins when it dominates all fields" {
    const local = localRecord(100, 100, 0.3, "zebra");
    const remote = remoteRecord(200, 200, 0.9, "alpha");
    const outcome = resolve(local, remote);
    try testing.expect(outcome.winner == .remote);
    try testing.expect(outcome.decided_by == .last_confirmed_wins);
}

// ── resolveWith policy tests ──────────────────────────────────────

test "resolveWith last_writer_wins ignores confirmation" {
    const local = localRecord(999, 0, 0.1, "zebra");
    const remote = remoteRecord(100, 9999, 0.9, "alpha");
    const outcome = resolveWith(local, remote, .last_writer_wins);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .last_writer_wins);
}

test "resolveWith highest_confidence ignores timestamps" {
    const local = localRecord(100, 100, 0.95, "zebra");
    const remote = remoteRecord(999, 999, 0.5, "alpha");
    const outcome = resolveWith(local, remote, .highest_confidence);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .highest_confidence);
}

test "resolveWith last_confirmed_wins falls back to source on tie" {
    const local = localRecord(100, 200, 0.5, "alpha");
    const remote = remoteRecord(100, 200, 0.5, "beta");
    const outcome = resolveWith(local, remote, .last_confirmed_wins);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .source_priority);
}

test "resolveWith source_priority only uses node ordering" {
    const local = localRecord(999, 999, 0.99, "zebra");
    const remote = remoteRecord(100, 100, 0.1, "alpha");
    const outcome = resolveWith(local, remote, .source_priority);
    try testing.expect(outcome.winner == .remote);
    try testing.expect(outcome.decided_by == .source_priority);
}

// ── Symmetry / determinism tests ──────────────────────────────────

test "resolve is deterministic: same inputs produce same output" {
    const a = localRecord(300, 200, 0.8, "huginn");
    const b = remoteRecord(400, 100, 0.7, "muninn");
    const o1 = resolve(a, b);
    const o2 = resolve(a, b);
    try testing.expect(o1.winner == o2.winner);
    try testing.expect(o1.decided_by == o2.decided_by);
}

test "resolve tiebreaker is antisymmetric: swapping sides flips winner" {
    // When all scored fields are equal, node ID decides.
    // "huginn" < "muninn" lexicographically, so whoever has "huginn" wins.
    const a = ConflictRecord{
        .source_node = .{ .id = "huginn" },
        .updated_at = 100,
        .last_confirmed_at = 100,
        .confidence = 0.5,
    };
    const b = ConflictRecord{
        .source_node = .{ .id = "muninn" },
        .updated_at = 100,
        .last_confirmed_at = 100,
        .confidence = 0.5,
    };
    // a as local, b as remote -> local wins (huginn < muninn)
    const o1 = resolve(a, b);
    try testing.expect(o1.winner == .local);

    // b as local, a as remote -> remote wins (huginn < muninn)
    const o2 = resolve(b, a);
    try testing.expect(o2.winner == .remote);
}

// ── Edge cases ────────────────────────────────────────────────────

test "resolve: zero-value records fall through to source_priority" {
    const local = ConflictRecord{
        .source_node = .{ .id = "aaa" },
        .updated_at = 0,
    };
    const remote = ConflictRecord{
        .source_node = .{ .id = "zzz" },
        .updated_at = 0,
    };
    const outcome = resolve(local, remote);
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .source_priority);
}

test "resolve: negative timestamps handled correctly" {
    const local = localRecord(-100, -50, 0.5, "alpha");
    const remote = remoteRecord(-200, -100, 0.5, "beta");
    const outcome = resolve(local, remote);
    // -50 > -100, so local wins on confirmed
    try testing.expect(outcome.winner == .local);
    try testing.expect(outcome.decided_by == .last_confirmed_wins);
}

test "ConflictRecord defaults" {
    const rec = ConflictRecord{
        .source_node = .{ .id = "test" },
        .updated_at = 1000,
    };
    try testing.expectEqual(@as(Timestamp, 0), rec.last_confirmed_at);
    try testing.expect(rec.confidence == 0.0);
    try testing.expectEqual(@as(SequenceNum, 0), rec.sequence);
}
