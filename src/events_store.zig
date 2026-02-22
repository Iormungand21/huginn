//! JSONL file sink for the structured event timeline.
//!
//! Provides `EventStore` — a minimal append-only sink that serializes
//! `TimelineEvent` records as newline-delimited JSON to a local file.
//! Each call to `append` writes one line; there is no internal buffering
//! beyond the OS page cache, so events survive crashes at the cost of
//! one syscall per event.
//!
//! Thread safety: the store uses a mutex so multiple goroutines/threads
//! can append concurrently. The file is opened/closed per write to avoid
//! holding a file descriptor across long idle periods.
//!
//! Future stages may add rotation, compression, or in-memory ring buffers.

const std = @import("std");
const events = @import("events.zig");
const TimelineEvent = events.TimelineEvent;

// ── EventStore ─────────────────────────────────────────────────────
/// Append-only JSONL file sink for `TimelineEvent` records.
pub const EventStore = struct {
    /// Filesystem path for the JSONL output file.
    path: []const u8,
    /// Monotonic event counter used when callers need auto-generated IDs.
    seq: std.atomic.Value(u64),
    /// Guards concurrent appends.
    mutex: std.Thread.Mutex,

    /// Create a new EventStore targeting the given file path.
    /// The file is created on first write if it does not exist.
    pub fn init(path: []const u8) EventStore {
        return .{
            .path = path,
            .seq = std.atomic.Value(u64).init(0),
            .mutex = .{},
        };
    }

    /// Append a single event as a JSONL line to the sink file.
    /// Returns `true` on success, `false` if serialization or I/O failed.
    /// Errors are silently swallowed to match the fire-and-forget
    /// semantics of the existing `FileObserver` in `observability.zig`.
    pub fn append(self: *EventStore, event: *const TimelineEvent) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [4096]u8 = undefined;
        const line = event.formatJsonLine(&buf) orelse return false;

        self.appendRaw(line);
        return true;
    }

    /// Return the next monotonic sequence number (atomic, lock-free).
    pub fn nextSeq(self: *EventStore) u64 {
        return self.seq.fetchAdd(1, .monotonic);
    }

    /// Low-level: append an already-formatted line to the sink file.
    /// Caller must hold the mutex.
    fn appendRaw(self: *EventStore, line: []const u8) void {
        const file = std.fs.cwd().openFile(self.path, .{ .mode = .write_only }) catch {
            const new_file = std.fs.cwd().createFile(self.path, .{ .truncate = false }) catch return;
            defer new_file.close();
            new_file.seekFromEnd(0) catch return;
            new_file.writeAll(line) catch return;
            new_file.writeAll("\n") catch return;
            return;
        };
        defer file.close();
        file.seekFromEnd(0) catch return;
        file.writeAll(line) catch return;
        file.writeAll("\n") catch return;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "EventStore init" {
    const store = EventStore.init("/tmp/nullclaw_events_test.jsonl");
    try std.testing.expectEqualStrings("/tmp/nullclaw_events_test.jsonl", store.path);
    try std.testing.expectEqual(@as(u64, 0), store.seq.load(.monotonic));
}

test "EventStore nextSeq increments" {
    var store = EventStore.init("/tmp/unused.jsonl");
    try std.testing.expectEqual(@as(u64, 0), store.nextSeq());
    try std.testing.expectEqual(@as(u64, 1), store.nextSeq());
    try std.testing.expectEqual(@as(u64, 2), store.nextSeq());
    try std.testing.expectEqual(@as(u64, 3), store.seq.load(.monotonic));
}

test "EventStore append writes JSONL" {
    const path = "/tmp/nullclaw_events_store_test.jsonl";
    // Clean up any leftover file
    std.fs.cwd().deleteFile(path) catch {};

    var store = EventStore.init(path);
    const ev = TimelineEvent{
        .id = "test-1",
        .timestamp_ns = 12345,
        .name = "store.test",
    };
    const ok = store.append(&ev);
    try std.testing.expect(ok);

    // Read back and verify
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    const n = try file.readAll(&read_buf);
    const content = read_buf[0..n];

    // Should contain the event fields
    try std.testing.expect(std.mem.indexOf(u8, content, "\"id\":\"test-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"name\":\"store.test\"") != null);
    // Should end with newline
    try std.testing.expect(content[content.len - 1] == '\n');

    // Clean up
    std.fs.cwd().deleteFile(path) catch {};
}

test "EventStore append multiple events" {
    const path = "/tmp/nullclaw_events_multi_test.jsonl";
    std.fs.cwd().deleteFile(path) catch {};

    var store = EventStore.init(path);
    for (0..3) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "evt-{d}", .{i}) catch unreachable;
        const ev = TimelineEvent{
            .id = id,
            .timestamp_ns = @as(i128, @intCast(i)) * 1000,
            .name = "multi.test",
        };
        try std.testing.expect(store.append(&ev));
    }

    // Read back and count lines
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var read_buf: [8192]u8 = undefined;
    const n = try file.readAll(&read_buf);
    const content = read_buf[0..n];

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), line_count);

    std.fs.cwd().deleteFile(path) catch {};
}

test "EventStore append returns false on buffer overflow" {
    var store = EventStore.init("/tmp/unused_overflow.jsonl");
    // Create an event with a very long name that would exceed the 4096 buffer
    const long_name = "x" ** 4096;
    const ev = TimelineEvent{
        .id = "overflow",
        .timestamp_ns = 0,
        .name = long_name,
    };
    const ok = store.append(&ev);
    try std.testing.expect(!ok);
}
