const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const bus = @import("../bus.zig");

/// Message dispatch — routes incoming ChannelMessages to the agent,
/// routes agent responses back to the originating channel.
///
/// This module replaces the Rust channels/mod.rs orchestration:
/// - start_channels, process_channel_message, build_system_prompt
///
/// Zig doesn't have async/await, so channels will be started
/// synchronously or via thread spawning.
pub const ChannelRegistry = struct {
    allocator: std.mem.Allocator,
    channels: std.ArrayListUnmanaged(root.Channel),

    pub fn init(allocator: std.mem.Allocator) ChannelRegistry {
        return .{
            .allocator = allocator,
            .channels = .empty,
        };
    }

    pub fn deinit(self: *ChannelRegistry) void {
        self.channels.deinit(self.allocator);
    }

    pub fn register(self: *ChannelRegistry, ch: root.Channel) !void {
        try self.channels.append(self.allocator, ch);
    }

    pub fn count(self: *const ChannelRegistry) usize {
        return self.channels.items.len;
    }

    /// Find a channel by name.
    pub fn findByName(self: *const ChannelRegistry, channel_name: []const u8) ?root.Channel {
        for (self.channels.items) |ch| {
            if (std.mem.eql(u8, ch.name(), channel_name)) return ch;
        }
        return null;
    }

    /// Start all registered channels.
    pub fn startAll(self: *ChannelRegistry) !void {
        for (self.channels.items) |ch| {
            try ch.start();
        }
    }

    /// Stop all registered channels.
    pub fn stopAll(self: *ChannelRegistry) void {
        for (self.channels.items) |ch| {
            ch.stop();
        }
    }

    /// Run health checks on all channels.
    pub fn healthCheckAll(self: *const ChannelRegistry) HealthReport {
        var healthy: usize = 0;
        var unhealthy: usize = 0;
        for (self.channels.items) |ch| {
            if (ch.healthCheck()) {
                healthy += 1;
            } else {
                unhealthy += 1;
            }
        }
        return .{ .healthy = healthy, .unhealthy = unhealthy, .total = self.channels.items.len };
    }

    /// Get names of all registered channels.
    pub fn channelNames(self: *const ChannelRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(allocator);
        for (self.channels.items) |ch| {
            try names.append(allocator, ch.name());
        }
        return names.toOwnedSlice(allocator);
    }
};

pub const HealthReport = struct {
    healthy: usize,
    unhealthy: usize,
    total: usize,

    pub fn allHealthy(self: HealthReport) bool {
        return self.unhealthy == 0 and self.total > 0;
    }
};

/// Build a system prompt with channel context.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    base_prompt: []const u8,
    channel_name: []const u8,
    identity_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nYou are {s}. You are responding on the {s} channel.",
        .{ base_prompt, identity_name, channel_name },
    );
}

// ════════════════════════════════════════════════════════════════════════════
// Outbound Dispatch Loop
// ════════════════════════════════════════════════════════════════════════════

/// Counters for the outbound dispatch loop (all atomic for thread safety).
pub const DispatchStats = struct {
    dispatched: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    channel_not_found: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn getDispatched(self: *const DispatchStats) u64 {
        return self.dispatched.load(.monotonic);
    }

    pub fn getErrors(self: *const DispatchStats) u64 {
        return self.errors.load(.monotonic);
    }

    pub fn getChannelNotFound(self: *const DispatchStats) u64 {
        return self.channel_not_found.load(.monotonic);
    }
};

/// Run the outbound dispatch loop. Blocks until the bus is closed.
/// Consumes messages from `bus.consumeOutbound()` and routes them to the
/// appropriate channel via `registry.findByName(msg.channel)`.
///
/// Designed to run in a dedicated thread:
///   `std.Thread.spawn(.{}, runOutboundDispatcher, .{ alloc, &bus, &registry, &stats })`
///
/// The loop exits when `bus.close()` is called and the outbound queue is drained.
pub fn runOutboundDispatcher(
    allocator: Allocator,
    event_bus: *bus.Bus,
    registry: *const ChannelRegistry,
    stats: *DispatchStats,
) void {
    while (event_bus.consumeOutbound()) |msg| {
        defer msg.deinit(allocator);

        if (registry.findByName(msg.channel)) |channel| {
            channel.send(msg.chat_id, msg.content) catch {
                _ = stats.errors.fetchAdd(1, .monotonic);
                continue;
            };
            _ = stats.dispatched.fetchAdd(1, .monotonic);
        } else {
            _ = stats.channel_not_found.fetchAdd(1, .monotonic);
        }
    }
}

/// Get names of all enabled (registered) channels.
pub fn getEnabledChannelNames(registry: *const ChannelRegistry, allocator: Allocator) ![][]const u8 {
    return registry.channelNames(allocator);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "channel registry init and count" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "channel registry register and find" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var cli_ch = @import("cli.zig").CliChannel.init(allocator);
    try reg.register(cli_ch.channel());

    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.findByName("cli") != null);
    try std.testing.expect(reg.findByName("nonexistent") == null);
}

test "channel registry health check all" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var cli_ch = @import("cli.zig").CliChannel.init(allocator);
    try reg.register(cli_ch.channel());

    const report = reg.healthCheckAll();
    try std.testing.expectEqual(@as(usize, 1), report.healthy);
    try std.testing.expectEqual(@as(usize, 0), report.unhealthy);
    try std.testing.expect(report.allHealthy());
}

test "channel registry channel names" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var cli_ch = @import("cli.zig").CliChannel.init(allocator);
    try reg.register(cli_ch.channel());

    const names = try reg.channelNames(allocator);
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("cli", names[0]);
}

test "health report all healthy" {
    const report = HealthReport{ .healthy = 3, .unhealthy = 0, .total = 3 };
    try std.testing.expect(report.allHealthy());
}

test "health report not all healthy" {
    const report = HealthReport{ .healthy = 2, .unhealthy = 1, .total = 3 };
    try std.testing.expect(!report.allHealthy());
}

test "health report empty is not healthy" {
    const report = HealthReport{ .healthy = 0, .unhealthy = 0, .total = 0 };
    try std.testing.expect(!report.allHealthy());
}

test "build system prompt" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Be helpful.", "telegram", "nullclaw");
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Be helpful.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "nullclaw") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "telegram") != null);
}

// ════════════════════════════════════════════════════════════════════════════
// Outbound Dispatch Tests
// ════════════════════════════════════════════════════════════════════════════

/// Mock channel for dispatch tests.
const MockChannel = struct {
    name_str: []const u8,
    sent_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    should_fail: bool = false,

    const vtable = root.Channel.VTable{
        .start = mockStart,
        .stop = mockStop,
        .send = mockSend,
        .name = mockName,
        .healthCheck = mockHealthCheck,
    };

    fn channel(self: *MockChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockStart(_: *anyopaque) anyerror!void {}
    fn mockStop(_: *anyopaque) void {}
    fn mockSend(ctx: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        const self: *MockChannel = @ptrCast(@alignCast(ctx));
        if (self.should_fail) return error.SendFailed;
        _ = self.sent_count.fetchAdd(1, .monotonic);
    }
    fn mockName(ctx: *anyopaque) []const u8 {
        const self: *const MockChannel = @ptrCast(@alignCast(ctx));
        return self.name_str;
    }
    fn mockHealthCheck(_: *anyopaque) bool {
        return true;
    }
};

test "DispatchStats init all zero" {
    const stats = DispatchStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
}

test "dispatcher routes message to correct channel" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // Publish a message, then close bus so dispatcher exits
    const msg = try bus.makeOutbound(allocator, "telegram", "chat1", "hello");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 1), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
    try std.testing.expectEqual(@as(u64, 1), mock_tg.sent_count.load(.monotonic));
}

test "dispatcher increments channel_not_found for unknown channel" {
    const allocator = std.testing.allocator;

    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    // Empty registry — no channels registered

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const msg = try bus.makeOutbound(allocator, "nonexistent", "chat1", "hi");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), stats.getChannelNotFound());
}

test "dispatcher increments errors on channel.send failure" {
    const allocator = std.testing.allocator;

    var mock_fail = MockChannel{ .name_str = "failing", .should_fail = true };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_fail.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const msg = try bus.makeOutbound(allocator, "failing", "c1", "boom");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
}

test "dispatcher handles multiple messages" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var mock_dc = MockChannel{ .name_str = "discord" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());
    try reg.register(mock_dc.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // 3 to telegram, 2 to discord
    for (0..3) |_| {
        const msg = try bus.makeOutbound(allocator, "telegram", "c1", "msg");
        try event_bus.publishOutbound(msg);
    }
    for (0..2) |_| {
        const msg = try bus.makeOutbound(allocator, "discord", "c2", "msg");
        try event_bus.publishOutbound(msg);
    }
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 5), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 3), mock_tg.sent_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), mock_dc.sent_count.load(.monotonic));
}

test "dispatcher mixed: found, not_found, error" {
    const allocator = std.testing.allocator;

    var mock_ok = MockChannel{ .name_str = "telegram" };
    var mock_fail = MockChannel{ .name_str = "broken", .should_fail = true };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_ok.channel());
    try reg.register(mock_fail.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // 1 ok, 1 error, 1 not found
    const m1 = try bus.makeOutbound(allocator, "telegram", "c1", "ok");
    try event_bus.publishOutbound(m1);
    const m2 = try bus.makeOutbound(allocator, "broken", "c2", "fail");
    try event_bus.publishOutbound(m2);
    const m3 = try bus.makeOutbound(allocator, "ghost", "c3", "where");
    try event_bus.publishOutbound(m3);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 1), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 1), stats.getChannelNotFound());
}

test "dispatcher empty bus returns immediately" {
    const allocator = std.testing.allocator;

    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
}

test "dispatcher runs in a separate thread" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // Spawn dispatcher thread
    const thread = try std.Thread.spawn(.{}, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    // Publish from main thread
    const msg = try bus.makeOutbound(allocator, "telegram", "c1", "threaded");
    try event_bus.publishOutbound(msg);

    // Small delay then close bus to let dispatcher process
    std.Thread.sleep(10 * std.time.ns_per_ms);
    event_bus.close();
    thread.join();

    try std.testing.expectEqual(@as(u64, 1), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), mock_tg.sent_count.load(.monotonic));
}

test "dispatcher concurrent producers + single dispatcher" {
    const allocator = std.testing.allocator;

    var mock_ch = MockChannel{ .name_str = "test" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_ch.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const num_producers = 4;
    const msgs_per_producer = 25;
    const total = num_producers * msgs_per_producer;

    // Spawn dispatcher
    const dispatcher = try std.Thread.spawn(.{}, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    // Spawn producers
    var producers: [num_producers]std.Thread = undefined;
    for (0..num_producers) |i| {
        producers[i] = try std.Thread.spawn(.{}, struct {
            fn run(b: *bus.Bus, a: Allocator) void {
                for (0..msgs_per_producer) |_| {
                    const m = bus.makeOutbound(a, "test", "c", "x") catch return;
                    b.publishOutbound(m) catch return;
                }
            }
        }.run, .{ &event_bus, allocator });
    }

    // Wait for all producers, then close bus
    for (&producers) |*p| p.join();
    // Small delay for dispatcher to drain
    std.Thread.sleep(20 * std.time.ns_per_ms);
    event_bus.close();
    dispatcher.join();

    try std.testing.expectEqual(@as(u64, total), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, total), mock_ch.sent_count.load(.monotonic));
}

test "getEnabledChannelNames returns registered names" {
    const allocator = std.testing.allocator;

    var mock1 = MockChannel{ .name_str = "telegram" };
    var mock2 = MockChannel{ .name_str = "discord" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock1.channel());
    try reg.register(mock2.channel());

    const names = try getEnabledChannelNames(&reg, allocator);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("telegram", names[0]);
    try std.testing.expectEqualStrings("discord", names[1]);
}
