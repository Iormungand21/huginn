//! Typed memory record schema and metadata primitives.
//!
//! Provides structured types for classifying, tiering, and annotating memory
//! records. These types layer on top of the existing `MemoryEntry` without
//! changing backend storage — a future migration task will persist them.

const std = @import("std");

// ── Memory kind ────────────────────────────────────────────────────
/// Semantic classification of a memory record's content.
pub const MemoryKind = enum {
    /// Long-lived knowledge (facts, preferences, project conventions).
    semantic,
    /// Time-bound experience (conversation excerpt, event log entry).
    episodic,
    /// Reusable procedure or tool-use pattern.
    procedural,

    pub fn toString(self: MemoryKind) []const u8 {
        return switch (self) {
            .semantic => "semantic",
            .episodic => "episodic",
            .procedural => "procedural",
        };
    }

    pub fn fromString(s: []const u8) ?MemoryKind {
        if (std.mem.eql(u8, s, "semantic")) return .semantic;
        if (std.mem.eql(u8, s, "episodic")) return .episodic;
        if (std.mem.eql(u8, s, "procedural")) return .procedural;
        return null;
    }
};

// ── Memory tier ────────────────────────────────────────────────────
/// Retention tier controlling how aggressively a record is pruned.
pub const MemoryTier = enum {
    /// Pinned — never auto-pruned.
    pinned,
    /// Standard retention; subject to normal decay.
    standard,
    /// Ephemeral — eligible for aggressive pruning.
    ephemeral,

    pub fn toString(self: MemoryTier) []const u8 {
        return switch (self) {
            .pinned => "pinned",
            .standard => "standard",
            .ephemeral => "ephemeral",
        };
    }

    pub fn fromString(s: []const u8) ?MemoryTier {
        if (std.mem.eql(u8, s, "pinned")) return .pinned;
        if (std.mem.eql(u8, s, "standard")) return .standard;
        if (std.mem.eql(u8, s, "ephemeral")) return .ephemeral;
        return null;
    }
};

// ── Source metadata ────────────────────────────────────────────────
/// Provenance information describing where a memory record originated.
pub const SourceMeta = struct {
    /// The agent or user that created this record (e.g. "user", "planner", "worker").
    origin: []const u8 = "unknown",
    /// Identifier for the session or task that produced this record.
    context_id: ?[]const u8 = null,
    /// Free-form tag for the tool or action that generated the content.
    tool_tag: ?[]const u8 = null,

    /// Free all owned strings. Caller must ensure strings were heap-allocated
    /// by the same allocator.
    pub fn deinit(self: *const SourceMeta, allocator: std.mem.Allocator) void {
        if (!std.mem.eql(u8, self.origin, "unknown")) {
            allocator.free(self.origin);
        }
        if (self.context_id) |cid| allocator.free(cid);
        if (self.tool_tag) |tt| allocator.free(tt);
    }
};

// ── Typed memory record ────────────────────────────────────────────
/// A memory record enriched with kind, tier, and source metadata.
/// Designed to wrap or extend the existing `MemoryEntry` with structured
/// classification without altering backend storage (yet).
pub const TypedRecord = struct {
    /// Opaque record identifier (matches MemoryEntry.id when bridged).
    id: []const u8,
    /// Human-readable key or title.
    key: []const u8,
    /// The actual content body.
    content: []const u8,
    /// Semantic kind of this record.
    kind: MemoryKind = .semantic,
    /// Retention tier.
    tier: MemoryTier = .standard,
    /// Provenance metadata.
    source: SourceMeta = .{},
    /// Confidence score in [0, 1]; null means unscored.
    confidence: ?f64 = null,
    /// ISO-8601 creation timestamp.
    created_at: []const u8,
    /// ISO-8601 timestamp of last access (for decay tracking).
    last_accessed: ?[]const u8 = null,

    /// Free all heap-allocated fields.
    pub fn deinit(self: *const TypedRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.content);
        self.source.deinit(allocator);
        allocator.free(self.created_at);
        if (self.last_accessed) |la| allocator.free(la);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "MemoryKind toString roundtrip" {
    try std.testing.expectEqualStrings("semantic", MemoryKind.semantic.toString());
    try std.testing.expectEqualStrings("episodic", MemoryKind.episodic.toString());
    try std.testing.expectEqualStrings("procedural", MemoryKind.procedural.toString());
}

test "MemoryKind fromString valid" {
    try std.testing.expect(MemoryKind.fromString("semantic").? == .semantic);
    try std.testing.expect(MemoryKind.fromString("episodic").? == .episodic);
    try std.testing.expect(MemoryKind.fromString("procedural").? == .procedural);
}

test "MemoryKind fromString invalid returns null" {
    try std.testing.expect(MemoryKind.fromString("bogus") == null);
    try std.testing.expect(MemoryKind.fromString("") == null);
}

test "MemoryTier toString roundtrip" {
    try std.testing.expectEqualStrings("pinned", MemoryTier.pinned.toString());
    try std.testing.expectEqualStrings("standard", MemoryTier.standard.toString());
    try std.testing.expectEqualStrings("ephemeral", MemoryTier.ephemeral.toString());
}

test "MemoryTier fromString valid" {
    try std.testing.expect(MemoryTier.fromString("pinned").? == .pinned);
    try std.testing.expect(MemoryTier.fromString("standard").? == .standard);
    try std.testing.expect(MemoryTier.fromString("ephemeral").? == .ephemeral);
}

test "MemoryTier fromString invalid returns null" {
    try std.testing.expect(MemoryTier.fromString("bogus") == null);
    try std.testing.expect(MemoryTier.fromString("") == null);
}

test "SourceMeta defaults" {
    const meta = SourceMeta{};
    try std.testing.expectEqualStrings("unknown", meta.origin);
    try std.testing.expect(meta.context_id == null);
    try std.testing.expect(meta.tool_tag == null);
}

test "TypedRecord defaults" {
    const rec = TypedRecord{
        .id = "test-id",
        .key = "test-key",
        .content = "hello",
        .created_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(rec.kind == .semantic);
    try std.testing.expect(rec.tier == .standard);
    try std.testing.expect(rec.confidence == null);
    try std.testing.expect(rec.last_accessed == null);
    try std.testing.expectEqualStrings("unknown", rec.source.origin);
}

test "TypedRecord with explicit fields" {
    const rec = TypedRecord{
        .id = "id-1",
        .key = "my-key",
        .content = "some content",
        .kind = .episodic,
        .tier = .ephemeral,
        .source = .{ .origin = "planner", .context_id = "task-42", .tool_tag = "web_fetch" },
        .confidence = 0.85,
        .created_at = "2026-02-22T12:00:00Z",
        .last_accessed = "2026-02-22T13:00:00Z",
    };
    try std.testing.expect(rec.kind == .episodic);
    try std.testing.expect(rec.tier == .ephemeral);
    try std.testing.expect(rec.confidence.? == 0.85);
    try std.testing.expectEqualStrings("planner", rec.source.origin);
    try std.testing.expectEqualStrings("task-42", rec.source.context_id.?);
    try std.testing.expectEqualStrings("web_fetch", rec.source.tool_tag.?);
    try std.testing.expectEqualStrings("2026-02-22T13:00:00Z", rec.last_accessed.?);
}
