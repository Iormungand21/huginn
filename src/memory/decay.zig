//! Confidence decay and recency scoring primitives.
//!
//! Provides pure functions for computing how memory confidence erodes over time,
//! with different decay rates for episodic vs semantic vs procedural memories
//! and tier-based multipliers. All functions are deterministic and side-effect-free.
//!
//! ## Decay model
//!
//! Uses exponential half-life decay:
//!   decayed = floor + (initial - floor) * 0.5^(elapsed / half_life)
//!
//! Half-lives vary by MemoryKind (episodic decays fast, semantic slow) and
//! MemoryTier (pinned never decays, ephemeral decays faster).
//!
//! ## Integration TODOs
//!
//! - [ ] Wire `effectiveConfidence` into recall/search ranking in sqlite.zig
//! - [ ] Call `recencyScore` from hygiene.zig to prioritize pruning candidates
//! - [ ] Persist decayed confidence on read (lazy write-back) in backends
//! - [ ] Add `decay_half_life_hours` to config/agent settings for user tuning
//! - [ ] Integrate with vector.zig hybridMerge for decay-weighted scoring

const std = @import("std");
const types = @import("types.zig");

pub const MemoryKind = types.MemoryKind;
pub const MemoryTier = types.MemoryTier;

// ── Decay parameters ─────────────────────────────────────────────

/// Configurable parameters for the exponential decay function.
pub const DecayParams = struct {
    /// Hours for confidence to halve. Must be positive.
    half_life_hours: f64,
    /// Minimum confidence after decay. Clamped to [0, 1].
    floor: f64 = 0.0,
};

// ── Default half-lives per kind ──────────────────────────────────

/// Default half-life in hours for each MemoryKind.
///
/// - semantic:   720 h (30 days) — facts and preferences persist long
/// - episodic:    48 h (2 days)  — experiences fade quickly
/// - procedural: 168 h (7 days)  — procedures have moderate retention
pub fn defaultHalfLifeHours(kind: MemoryKind) f64 {
    return switch (kind) {
        .semantic => 720.0,
        .episodic => 48.0,
        .procedural => 168.0,
    };
}

// ── Tier multipliers ─────────────────────────────────────────────

/// Multiplier applied to the half-life based on retention tier.
///
/// A higher multiplier means slower decay (longer effective half-life).
/// - pinned:    returns `std.math.inf(f64)` — no decay
/// - standard:  1.0 — normal rate
/// - ephemeral: 0.25 — 4x faster decay
pub fn tierMultiplier(tier: MemoryTier) f64 {
    return switch (tier) {
        .pinned => std.math.inf(f64),
        .standard => 1.0,
        .ephemeral => 0.25,
    };
}

// ── Core decay function ──────────────────────────────────────────

/// Compute decayed confidence using exponential half-life decay.
///
/// Returns `floor + (initial - floor) * 0.5^(elapsed_hours / half_life_hours)`.
///
/// Guarantees:
/// - Result is clamped to [0, 1].
/// - If `half_life_hours` is infinite (pinned), returns `initial` unchanged.
/// - If `elapsed_hours` <= 0, returns `initial` unchanged.
/// - If `initial` <= floor, returns `floor`.
pub fn decayedConfidence(initial: f64, elapsed_hours: f64, params: DecayParams) f64 {
    // Clamp floor to valid range.
    const floor = @min(@max(params.floor, 0.0), 1.0);

    // No decay for non-positive elapsed time.
    if (elapsed_hours <= 0.0) return clamp01(initial);

    // No decay for infinite half-life (pinned).
    if (std.math.isInf(params.half_life_hours)) return clamp01(initial);

    // Guard against zero/negative half-life.
    if (params.half_life_hours <= 0.0) return floor;

    // If initial is already at or below floor, return floor.
    if (initial <= floor) return floor;

    const exponent = elapsed_hours / params.half_life_hours;
    const factor = std.math.pow(f64, 0.5, exponent);
    const result = floor + (initial - floor) * factor;

    return clamp01(result);
}

// ── Convenience: effective confidence for a kind+tier ────────────

/// Compute the effective (decayed) confidence for a memory record, given its
/// kind, tier, initial confidence, and elapsed hours since creation or last access.
///
/// Combines `defaultHalfLifeHours(kind) * tierMultiplier(tier)` to derive
/// the effective half-life, then applies `decayedConfidence`.
pub fn effectiveConfidence(
    kind: MemoryKind,
    tier: MemoryTier,
    initial_confidence: f64,
    elapsed_hours: f64,
) f64 {
    const base_hl = defaultHalfLifeHours(kind);
    const mult = tierMultiplier(tier);
    const effective_hl = base_hl * mult;

    return decayedConfidence(initial_confidence, elapsed_hours, .{
        .half_life_hours = effective_hl,
    });
}

// ── Recency scoring ──────────────────────────────────────────────

/// Compute a recency score in [0, 1] based on time since last access.
///
/// Uses the same exponential half-life model:
///   score = 0.5^(elapsed_hours / half_life_hours)
///
/// A recently accessed record scores close to 1.0; older ones approach 0.0.
/// If `half_life_hours` is infinite, always returns 1.0.
/// If `elapsed_hours` <= 0, returns 1.0.
pub fn recencyScore(elapsed_hours: f64, half_life_hours: f64) f64 {
    if (elapsed_hours <= 0.0) return 1.0;
    if (std.math.isInf(half_life_hours)) return 1.0;
    if (half_life_hours <= 0.0) return 0.0;

    const exponent = elapsed_hours / half_life_hours;
    const score = std.math.pow(f64, 0.5, exponent);
    return clamp01(score);
}

/// Recency score using the default half-life for the given MemoryKind,
/// adjusted by MemoryTier.
pub fn kindRecencyScore(kind: MemoryKind, tier: MemoryTier, elapsed_hours: f64) f64 {
    const hl = defaultHalfLifeHours(kind) * tierMultiplier(tier);
    return recencyScore(elapsed_hours, hl);
}

// ── Combined relevance scoring ───────────────────────────────────

/// Combine decayed confidence and recency into a single relevance score.
///
/// `relevance = alpha * decayed_confidence + (1 - alpha) * recency`
///
/// - `alpha` controls the weight: 1.0 = only confidence, 0.0 = only recency.
/// - Both inputs should be in [0, 1]; result is clamped to [0, 1].
pub fn combinedRelevance(decayed_confidence: f64, recency: f64, alpha: f64) f64 {
    const a = clamp01(alpha);
    return clamp01(a * clamp01(decayed_confidence) + (1.0 - a) * clamp01(recency));
}

// ── Elapsed time helpers ─────────────────────────────────────────

/// Convert an elapsed duration in seconds to hours.
pub fn elapsedToHours(elapsed_seconds: f64) f64 {
    return elapsed_seconds / 3600.0;
}

/// Compute elapsed seconds between two epoch timestamps.
/// Returns 0 if `now` <= `then` (no negative elapsed time).
pub fn elapsedSeconds(then_epoch_s: i64, now_epoch_s: i64) f64 {
    if (now_epoch_s <= then_epoch_s) return 0.0;
    return @floatFromInt(now_epoch_s - then_epoch_s);
}

// ── Internal helpers ─────────────────────────────────────────────

fn clamp01(v: f64) f64 {
    return @min(@max(v, 0.0), 1.0);
}

// ── Tests ────────────────────────────────────────────────────────

test "defaultHalfLifeHours returns expected values" {
    try std.testing.expectEqual(@as(f64, 720.0), defaultHalfLifeHours(.semantic));
    try std.testing.expectEqual(@as(f64, 48.0), defaultHalfLifeHours(.episodic));
    try std.testing.expectEqual(@as(f64, 168.0), defaultHalfLifeHours(.procedural));
}

test "tierMultiplier values" {
    try std.testing.expect(std.math.isInf(tierMultiplier(.pinned)));
    try std.testing.expectEqual(@as(f64, 1.0), tierMultiplier(.standard));
    try std.testing.expectEqual(@as(f64, 0.25), tierMultiplier(.ephemeral));
}

test "decayedConfidence no elapsed time returns initial" {
    const result = decayedConfidence(0.9, 0.0, .{ .half_life_hours = 100.0 });
    try std.testing.expectEqual(@as(f64, 0.9), result);
}

test "decayedConfidence negative elapsed returns initial" {
    const result = decayedConfidence(0.8, -5.0, .{ .half_life_hours = 100.0 });
    try std.testing.expectEqual(@as(f64, 0.8), result);
}

test "decayedConfidence at exactly one half-life" {
    const result = decayedConfidence(1.0, 100.0, .{ .half_life_hours = 100.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result, 1e-10);
}

test "decayedConfidence at two half-lives" {
    const result = decayedConfidence(1.0, 200.0, .{ .half_life_hours = 100.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), result, 1e-10);
}

test "decayedConfidence with floor" {
    // After many half-lives, should approach floor, not zero.
    const result = decayedConfidence(1.0, 10000.0, .{
        .half_life_hours = 10.0,
        .floor = 0.1,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result, 1e-6);
}

test "decayedConfidence floor prevents going below" {
    const result = decayedConfidence(0.5, 500.0, .{
        .half_life_hours = 10.0,
        .floor = 0.3,
    });
    // initial (0.5) > floor (0.3), so decay from 0.5 toward 0.3
    // After 50 half-lives the (0.5-0.3) delta is negligible
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), result, 1e-6);
}

test "decayedConfidence initial below floor returns floor" {
    const result = decayedConfidence(0.1, 10.0, .{
        .half_life_hours = 100.0,
        .floor = 0.5,
    });
    try std.testing.expectEqual(@as(f64, 0.5), result);
}

test "decayedConfidence infinite half-life (pinned) returns initial" {
    const result = decayedConfidence(0.75, 99999.0, .{
        .half_life_hours = std.math.inf(f64),
    });
    try std.testing.expectEqual(@as(f64, 0.75), result);
}

test "decayedConfidence zero half-life returns floor" {
    const result = decayedConfidence(0.9, 10.0, .{
        .half_life_hours = 0.0,
        .floor = 0.2,
    });
    try std.testing.expectEqual(@as(f64, 0.2), result);
}

test "decayedConfidence clamps above 1" {
    const result = decayedConfidence(1.5, 0.0, .{ .half_life_hours = 100.0 });
    try std.testing.expectEqual(@as(f64, 1.0), result);
}

test "effectiveConfidence semantic+standard at one half-life" {
    // semantic half-life = 720h, standard multiplier = 1.0 → hl = 720h
    const result = effectiveConfidence(.semantic, .standard, 1.0, 720.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result, 1e-10);
}

test "effectiveConfidence episodic+standard decays faster" {
    // episodic half-life = 48h
    const result = effectiveConfidence(.episodic, .standard, 1.0, 48.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result, 1e-10);
}

test "effectiveConfidence episodic+ephemeral decays fastest" {
    // episodic=48h * ephemeral=0.25 → effective hl = 12h
    const result = effectiveConfidence(.episodic, .ephemeral, 1.0, 12.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result, 1e-10);
}

test "effectiveConfidence pinned tier never decays" {
    const result = effectiveConfidence(.episodic, .pinned, 0.9, 99999.0);
    try std.testing.expectEqual(@as(f64, 0.9), result);
}

test "recencyScore at zero elapsed" {
    const score = recencyScore(0.0, 100.0);
    try std.testing.expectEqual(@as(f64, 1.0), score);
}

test "recencyScore at one half-life" {
    const score = recencyScore(100.0, 100.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), score, 1e-10);
}

test "recencyScore approaches zero for large elapsed" {
    const score = recencyScore(10000.0, 10.0);
    try std.testing.expect(score < 0.001);
}

test "recencyScore infinite half-life returns 1" {
    const score = recencyScore(99999.0, std.math.inf(f64));
    try std.testing.expectEqual(@as(f64, 1.0), score);
}

test "recencyScore zero half-life returns 0" {
    const score = recencyScore(10.0, 0.0);
    try std.testing.expectEqual(@as(f64, 0.0), score);
}

test "kindRecencyScore episodic vs semantic" {
    // After 48h: episodic recency = 0.5, semantic recency ≈ 0.954
    const ep = kindRecencyScore(.episodic, .standard, 48.0);
    const sem = kindRecencyScore(.semantic, .standard, 48.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), ep, 1e-10);
    try std.testing.expect(sem > 0.9); // semantic barely decayed
}

test "kindRecencyScore pinned always 1" {
    const score = kindRecencyScore(.episodic, .pinned, 99999.0);
    try std.testing.expectEqual(@as(f64, 1.0), score);
}

test "combinedRelevance pure confidence" {
    const r = combinedRelevance(0.8, 0.2, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), r, 1e-10);
}

test "combinedRelevance pure recency" {
    const r = combinedRelevance(0.8, 0.2, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), r, 1e-10);
}

test "combinedRelevance balanced" {
    const r = combinedRelevance(0.8, 0.4, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), r, 1e-10);
}

test "combinedRelevance clamps result" {
    const r = combinedRelevance(1.5, 1.5, 0.5);
    try std.testing.expectEqual(@as(f64, 1.0), r);
}

test "elapsedToHours" {
    try std.testing.expectEqual(@as(f64, 1.0), elapsedToHours(3600.0));
    try std.testing.expectEqual(@as(f64, 24.0), elapsedToHours(86400.0));
    try std.testing.expectEqual(@as(f64, 0.5), elapsedToHours(1800.0));
}

test "elapsedSeconds" {
    try std.testing.expectEqual(@as(f64, 3600.0), elapsedSeconds(1000, 4600));
    try std.testing.expectEqual(@as(f64, 0.0), elapsedSeconds(5000, 3000)); // now <= then
    try std.testing.expectEqual(@as(f64, 0.0), elapsedSeconds(1000, 1000)); // equal
}

test "full decay pipeline: episodic record after 3 days" {
    // Simulate an episodic record created 72h ago with initial confidence 0.9
    const initial = 0.9;
    const elapsed_h = 72.0;

    // episodic half-life = 48h, standard tier
    const decayed = effectiveConfidence(.episodic, .standard, initial, elapsed_h);
    const recency = kindRecencyScore(.episodic, .standard, elapsed_h);
    const relevance = combinedRelevance(decayed, recency, 0.6);

    // After 72h (1.5 half-lives): decayed ≈ 0.9 * 0.5^1.5 ≈ 0.318
    try std.testing.expect(decayed < 0.35);
    try std.testing.expect(decayed > 0.28);

    // Recency at 1.5 half-lives: ≈ 0.354
    try std.testing.expect(recency < 0.40);
    try std.testing.expect(recency > 0.30);

    // Combined: 0.6 * ~0.318 + 0.4 * ~0.354 ≈ 0.333
    try std.testing.expect(relevance < 0.40);
    try std.testing.expect(relevance > 0.25);
}

test "full decay pipeline: semantic record after 3 days" {
    // Semantic record barely decays over 72h (half-life = 720h)
    const initial = 0.9;
    const elapsed_h = 72.0;

    const decayed = effectiveConfidence(.semantic, .standard, initial, elapsed_h);
    const recency = kindRecencyScore(.semantic, .standard, elapsed_h);
    const relevance = combinedRelevance(decayed, recency, 0.6);

    // After 72h with 720h half-life: 0.9 * 0.5^0.1 ≈ 0.839
    try std.testing.expect(decayed > 0.8);

    // Recency barely dipped
    try std.testing.expect(recency > 0.9);

    // Combined stays high
    try std.testing.expect(relevance > 0.8);
}
