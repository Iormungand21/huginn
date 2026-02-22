//! Hub snapshot — versioned import/export pipeline for memory hub sync.
//!
//! Extends the basic snapshot module with:
//!   - Schema-versioned payloads for forward compatibility
//!   - TypedRecord-aware entries (kind, tier, source, confidence)
//!   - Structured metadata (source node, timestamps, entry counts)
//!
//! This is a skeleton for future cross-node sync; no remote transport yet.

const std = @import("std");
const root = @import("root.zig");
const types = @import("types.zig");
const json_util = @import("../json_util.zig");

const Memory = root.Memory;
const MemoryEntry = root.MemoryEntry;
const MemoryCategory = root.MemoryCategory;
const MemoryKind = types.MemoryKind;
const MemoryTier = types.MemoryTier;
const SourceMeta = types.SourceMeta;

// ── Schema version ─────────────────────────────────────────────────

/// Schema version for the hub snapshot format.
/// Increment when the payload structure changes in a breaking way.
pub const SCHEMA_VERSION: u32 = 1;

/// Magic header for quick format identification.
pub const FORMAT_MAGIC = "nullclaw-hub-snapshot";

// ── Snapshot metadata ──────────────────────────────────────────────

/// Metadata envelope describing a hub snapshot.
pub const HubSnapshotMeta = struct {
    /// Schema version of this snapshot.
    schema_version: u32 = SCHEMA_VERSION,
    /// Identifier for the node that produced this snapshot.
    source_node: []const u8 = "local",
    /// ISO-8601 timestamp when the snapshot was created.
    created_at: []const u8,
    /// Number of entries in the snapshot.
    entry_count: usize = 0,
    /// Format identifier.
    format: []const u8 = FORMAT_MAGIC,
};

// ── Snapshot entry ─────────────────────────────────────────────────

/// A single entry in a hub snapshot, carrying full TypedRecord metadata.
pub const HubSnapshotEntry = struct {
    /// Record key/title.
    key: []const u8,
    /// Content body.
    content: []const u8,
    /// Memory category (core, daily, conversation, custom).
    category: []const u8,
    /// Semantic kind (semantic, episodic, procedural).
    kind: []const u8 = "semantic",
    /// Retention tier (pinned, standard, ephemeral).
    tier: []const u8 = "standard",
    /// ISO-8601 timestamp.
    timestamp: []const u8,
    /// Confidence score in [0, 1]; null if unscored.
    confidence: ?f64 = null,
    /// Source origin (e.g. "user", "planner").
    source_origin: []const u8 = "unknown",
    /// Source context identifier.
    source_context_id: ?[]const u8 = null,
    /// Source tool tag.
    source_tool_tag: ?[]const u8 = null,
};

// ── Snapshot payload ───────────────────────────────────────────────

/// Complete hub snapshot payload: metadata envelope + entries.
pub const HubSnapshot = struct {
    meta: HubSnapshotMeta,
    entries: []const HubSnapshotEntry,
};

// ── Export ──────────────────────────────────────────────────────────

/// Serialize a HubSnapshot to JSON bytes.
/// Caller owns the returned slice.
pub fn serializeSnapshot(allocator: std.mem.Allocator, snap: HubSnapshot) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");

    // Meta object
    try buf.appendSlice(allocator, "  \"meta\":{");
    try appendJsonUint(&buf, allocator, "schema_version", snap.meta.schema_version);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(&buf, allocator, "format", snap.meta.format);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(&buf, allocator, "source_node", snap.meta.source_node);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(&buf, allocator, "created_at", snap.meta.created_at);
    try buf.append(allocator, ',');
    try appendJsonUint(&buf, allocator, "entry_count", snap.meta.entry_count);
    try buf.appendSlice(allocator, "},\n");

    // Entries array
    try buf.appendSlice(allocator, "  \"entries\":[\n");
    for (snap.entries, 0..) |entry, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try serializeEntry(&buf, allocator, entry);
    }
    try buf.appendSlice(allocator, "\n  ]\n");

    try buf.appendSlice(allocator, "}\n");

    return allocator.dupe(u8, buf.items);
}

fn serializeEntry(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, entry: HubSnapshotEntry) !void {
    try buf.appendSlice(allocator, "    {");
    try json_util.appendJsonKeyValue(buf, allocator, "key", entry.key);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "content", entry.content);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "category", entry.category);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "kind", entry.kind);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "tier", entry.tier);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "timestamp", entry.timestamp);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "source_origin", entry.source_origin);

    if (entry.confidence) |c| {
        try buf.append(allocator, ',');
        try appendJsonFloat(buf, allocator, "confidence", c);
    }
    if (entry.source_context_id) |cid| {
        try buf.append(allocator, ',');
        try json_util.appendJsonKeyValue(buf, allocator, "source_context_id", cid);
    }
    if (entry.source_tool_tag) |tt| {
        try buf.append(allocator, ',');
        try json_util.appendJsonKeyValue(buf, allocator, "source_tool_tag", tt);
    }

    try buf.append(allocator, '}');
}

/// Export current memory contents as a versioned hub snapshot.
/// Returns the serialized JSON bytes. Caller owns the returned slice.
pub fn exportHubSnapshot(
    allocator: std.mem.Allocator,
    mem: Memory,
    source_node: []const u8,
    timestamp: []const u8,
) ![]u8 {
    // List all core memories
    const entries = try mem.list(allocator, .core, null);
    defer root.freeEntries(allocator, entries);

    // Convert to hub snapshot entries
    var snap_entries = try allocator.alloc(HubSnapshotEntry, entries.len);
    defer allocator.free(snap_entries);

    for (entries, 0..) |entry, i| {
        snap_entries[i] = .{
            .key = entry.key,
            .content = entry.content,
            .category = entry.category.toString(),
            .timestamp = entry.timestamp,
        };
    }

    const snap = HubSnapshot{
        .meta = .{
            .schema_version = SCHEMA_VERSION,
            .source_node = source_node,
            .created_at = timestamp,
            .entry_count = entries.len,
        },
        .entries = snap_entries,
    };

    return serializeSnapshot(allocator, snap);
}

// ── Import ─────────────────────────────────────────────────────────

/// Result of a hub snapshot import operation.
pub const ImportResult = struct {
    /// Number of entries successfully imported.
    imported: usize,
    /// Number of entries skipped (e.g. already present or invalid).
    skipped: usize,
    /// Schema version of the imported snapshot.
    schema_version: u32,
};

/// Parse and import a hub snapshot from JSON bytes into memory.
/// Returns import statistics.
pub fn importHubSnapshot(
    allocator: std.mem.Allocator,
    mem: Memory,
    json_bytes: []const u8,
) !ImportResult {
    if (json_bytes.len == 0) return .{ .imported = 0, .skipped = 0, .schema_version = 0 };

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
        return .{ .imported = 0, .skipped = 0, .schema_version = 0 };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .imported = 0, .skipped = 0, .schema_version = 0 },
    };

    // Parse meta
    var schema_version: u32 = 0;
    if (root_obj.get("meta")) |meta_val| {
        const meta_obj = switch (meta_val) {
            .object => |o| o,
            else => null,
        };
        if (meta_obj) |mo| {
            // Validate format magic
            if (mo.get("format")) |fmt_val| {
                const fmt_str = switch (fmt_val) {
                    .string => |s| s,
                    else => "",
                };
                if (!std.mem.eql(u8, fmt_str, FORMAT_MAGIC)) {
                    return .{ .imported = 0, .skipped = 0, .schema_version = 0 };
                }
            }

            if (mo.get("schema_version")) |sv_val| {
                schema_version = switch (sv_val) {
                    .integer => |i| @intCast(@max(0, i)),
                    else => 0,
                };
            }
        }
    }

    // Only accept version 1 for now
    if (schema_version != SCHEMA_VERSION) {
        return .{ .imported = 0, .skipped = 0, .schema_version = schema_version };
    }

    // Parse entries
    const entries_val = root_obj.get("entries") orelse
        return .{ .imported = 0, .skipped = 0, .schema_version = schema_version };
    const entries_array = switch (entries_val) {
        .array => |a| a,
        else => return .{ .imported = 0, .skipped = 0, .schema_version = schema_version },
    };

    var imported: usize = 0;
    var skipped: usize = 0;

    for (entries_array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                skipped += 1;
                continue;
            },
        };

        const key = getJsonString(obj, "key") orelse {
            skipped += 1;
            continue;
        };
        const content = getJsonString(obj, "content") orelse {
            skipped += 1;
            continue;
        };

        // Parse category
        const cat_str = getJsonString(obj, "category") orelse "core";
        const category = MemoryCategory.fromString(cat_str);

        mem.store(key, content, category, null) catch {
            skipped += 1;
            continue;
        };
        imported += 1;
    }

    return .{
        .imported = imported,
        .skipped = skipped,
        .schema_version = schema_version,
    };
}

// ── Helpers ────────────────────────────────────────────────────────

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn appendJsonUint(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: usize) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    var int_buf: [24]u8 = undefined;
    const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch unreachable;
    try buf.appendSlice(allocator, int_str);
}

fn appendJsonFloat(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: f64) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    var float_buf: [32]u8 = undefined;
    const float_str = std.fmt.bufPrint(&float_buf, "{d:.6}", .{value}) catch unreachable;
    try buf.appendSlice(allocator, float_str);
}

// ── Tests ──────────────────────────────────────────────────────────

test "SCHEMA_VERSION is 1" {
    try std.testing.expectEqual(@as(u32, 1), SCHEMA_VERSION);
}

test "FORMAT_MAGIC is correct" {
    try std.testing.expectEqualStrings("nullclaw-hub-snapshot", FORMAT_MAGIC);
}

test "HubSnapshotMeta defaults" {
    const meta = HubSnapshotMeta{ .created_at = "2026-02-22T00:00:00Z" };
    try std.testing.expectEqual(@as(u32, 1), meta.schema_version);
    try std.testing.expectEqualStrings("local", meta.source_node);
    try std.testing.expectEqual(@as(usize, 0), meta.entry_count);
    try std.testing.expectEqualStrings(FORMAT_MAGIC, meta.format);
}

test "HubSnapshotEntry defaults" {
    const entry = HubSnapshotEntry{
        .key = "test",
        .content = "hello",
        .category = "core",
        .timestamp = "2026-02-22T00:00:00Z",
    };
    try std.testing.expectEqualStrings("semantic", entry.kind);
    try std.testing.expectEqualStrings("standard", entry.tier);
    try std.testing.expect(entry.confidence == null);
    try std.testing.expectEqualStrings("unknown", entry.source_origin);
    try std.testing.expect(entry.source_context_id == null);
    try std.testing.expect(entry.source_tool_tag == null);
}

test "serializeSnapshot empty snapshot" {
    const snap = HubSnapshot{
        .meta = .{
            .created_at = "2026-02-22T00:00:00Z",
            .entry_count = 0,
        },
        .entries = &.{},
    };
    const json = try serializeSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    const meta = root_obj.get("meta").?.object;
    try std.testing.expectEqual(@as(i64, 1), meta.get("schema_version").?.integer);
    try std.testing.expectEqualStrings(FORMAT_MAGIC, meta.get("format").?.string);
    try std.testing.expectEqualStrings("local", meta.get("source_node").?.string);
    try std.testing.expectEqual(@as(usize, 0), root_obj.get("entries").?.array.items.len);
}

test "serializeSnapshot with entries" {
    const entries = [_]HubSnapshotEntry{
        .{
            .key = "fact-1",
            .content = "Zig is great",
            .category = "core",
            .kind = "semantic",
            .tier = "pinned",
            .timestamp = "2026-02-22T12:00:00Z",
            .confidence = 0.95,
            .source_origin = "user",
        },
        .{
            .key = "event-1",
            .content = "User asked about snapshots",
            .category = "conversation",
            .kind = "episodic",
            .tier = "ephemeral",
            .timestamp = "2026-02-22T13:00:00Z",
            .source_context_id = "session-42",
            .source_tool_tag = "chat",
        },
    };

    const snap = HubSnapshot{
        .meta = .{
            .created_at = "2026-02-22T14:00:00Z",
            .source_node = "pi-hub",
            .entry_count = 2,
        },
        .entries = &entries,
    };

    const json = try serializeSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    // Parse back and verify
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    const meta = root_obj.get("meta").?.object;
    try std.testing.expectEqual(@as(i64, 2), meta.get("entry_count").?.integer);
    try std.testing.expectEqualStrings("pi-hub", meta.get("source_node").?.string);

    const arr = root_obj.get("entries").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);

    const e0 = arr.items[0].object;
    try std.testing.expectEqualStrings("fact-1", e0.get("key").?.string);
    try std.testing.expectEqualStrings("semantic", e0.get("kind").?.string);
    try std.testing.expectEqualStrings("pinned", e0.get("tier").?.string);

    const e1 = arr.items[1].object;
    try std.testing.expectEqualStrings("episodic", e1.get("kind").?.string);
    try std.testing.expectEqualStrings("session-42", e1.get("source_context_id").?.string);
}

test "importHubSnapshot empty bytes" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const result = try importHubSnapshot(std.testing.allocator, mem, "");
    try std.testing.expectEqual(@as(usize, 0), result.imported);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
}

test "importHubSnapshot invalid JSON" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const result = try importHubSnapshot(std.testing.allocator, mem, "not json");
    try std.testing.expectEqual(@as(usize, 0), result.imported);
}

test "importHubSnapshot wrong format magic" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const json =
        \\{"meta":{"schema_version":1,"format":"wrong"},"entries":[]}
    ;
    const result = try importHubSnapshot(std.testing.allocator, mem, json);
    try std.testing.expectEqual(@as(usize, 0), result.imported);
}

test "importHubSnapshot unsupported version" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const json =
        \\{"meta":{"schema_version":99,"format":"nullclaw-hub-snapshot"},"entries":[{"key":"k","content":"c","category":"core","timestamp":"t"}]}
    ;
    const result = try importHubSnapshot(std.testing.allocator, mem, json);
    try std.testing.expectEqual(@as(usize, 0), result.imported);
    try std.testing.expectEqual(@as(u32, 99), result.schema_version);
}

test "importHubSnapshot roundtrip via serialize" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    // Build a snapshot
    const entries = [_]HubSnapshotEntry{
        .{
            .key = "greeting",
            .content = "Hello from hub",
            .category = "core",
            .timestamp = "2026-02-22T00:00:00Z",
        },
    };
    const snap = HubSnapshot{
        .meta = .{
            .created_at = "2026-02-22T00:00:00Z",
            .entry_count = 1,
        },
        .entries = &entries,
    };

    // Serialize
    const json = try serializeSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    // Import
    const result = try importHubSnapshot(std.testing.allocator, mem, json);
    try std.testing.expectEqual(@as(usize, 1), result.imported);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expectEqual(@as(u32, 1), result.schema_version);

    // Verify memory contains the entry
    const count = try mem.count();
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "exportHubSnapshot with empty memory" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const json = try exportHubSnapshot(std.testing.allocator, mem, "test-node", "2026-02-22T00:00:00Z");
    defer std.testing.allocator.free(json);

    // Parse and verify
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const meta = parsed.value.object.get("meta").?.object;
    try std.testing.expectEqual(@as(i64, 0), meta.get("entry_count").?.integer);
    try std.testing.expectEqualStrings("test-node", meta.get("source_node").?.string);
}

test "exportHubSnapshot with entries" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    // Store some entries
    try mem.store("key1", "value1", .core, null);
    try mem.store("key2", "value2", .core, null);

    const json = try exportHubSnapshot(std.testing.allocator, mem, "pi-node", "2026-02-22T12:00:00Z");
    defer std.testing.allocator.free(json);

    // Parse and verify
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const meta = parsed.value.object.get("meta").?.object;
    try std.testing.expectEqual(@as(i64, 2), meta.get("entry_count").?.integer);

    const arr = parsed.value.object.get("entries").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
}

test "full export-import roundtrip" {
    const sqlite = @import("sqlite.zig");

    // Source memory
    var src_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer src_impl.deinit();
    const src_mem = src_impl.memory();

    try src_mem.store("fact", "the sky is blue", .core, null);
    try src_mem.store("pref", "user likes dark mode", .core, null);

    // Export
    const json = try exportHubSnapshot(std.testing.allocator, src_mem, "source", "2026-02-22T00:00:00Z");
    defer std.testing.allocator.free(json);

    // Destination memory
    var dst_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer dst_impl.deinit();
    const dst_mem = dst_impl.memory();

    // Import
    const result = try importHubSnapshot(std.testing.allocator, dst_mem, json);
    try std.testing.expectEqual(@as(usize, 2), result.imported);
    try std.testing.expectEqual(@as(u32, 1), result.schema_version);

    // Verify destination has the entries
    const count = try dst_mem.count();
    try std.testing.expectEqual(@as(usize, 2), count);
}
