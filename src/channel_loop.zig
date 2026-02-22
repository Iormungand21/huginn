//! Channel Loop — extracted consumer loops for daemon-supervised channels.
//!
//! Contains `ChannelRuntime` (shared dependencies for message processing)
//! and `runDiscordLoop` (the consumer thread function spawned by the
//! daemon supervisor).

const std = @import("std");
const Config = @import("config.zig").Config;
const discord_mod = @import("channels/discord.zig");
const bus_mod = @import("bus.zig");
const session_mod = @import("session.zig");
const providers = @import("providers/root.zig");
const memory_mod = @import("memory/root.zig");
const observability = @import("observability.zig");
const tools_mod = @import("tools/root.zig");
const mcp = @import("mcp.zig");
const health = @import("health.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.channel_loop);

// ════════════════════════════════════════════════════════════════════════════
// DiscordLoopState — shared state between supervisor and consumer thread
// ════════════════════════════════════════════════════════════════════════════

pub const DiscordLoopState = struct {
    /// Updated after each processed message — epoch seconds.
    last_activity: std.atomic.Value(i64),
    /// Supervisor sets this to ask the consumer thread to stop.
    stop_requested: std.atomic.Value(bool),
    /// Consumer thread handle for join().
    consumer_thread: ?std.Thread = null,

    pub fn init() DiscordLoopState {
        return .{
            .last_activity = std.atomic.Value(i64).init(std.time.timestamp()),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }
};

// Re-export centralized ProviderHolder from providers module.
pub const ProviderHolder = providers.ProviderHolder;

// ════════════════════════════════════════════════════════════════════════════
// ChannelRuntime — container for consumer-thread dependencies
// ════════════════════════════════════════════════════════════════════════════

pub const ChannelRuntime = struct {
    allocator: std.mem.Allocator,
    session_mgr: session_mod.SessionManager,
    provider_holder: *ProviderHolder,
    tools: []const tools_mod.Tool,
    mem: ?memory_mod.Memory,
    noop_obs: *observability.NoopObserver,

    /// Initialize the runtime from config — mirrors main.zig:702-786 setup.
    pub fn init(allocator: std.mem.Allocator, config: *const Config) !*ChannelRuntime {
        // Provider — heap-allocated for vtable pointer stability
        const holder = try allocator.create(ProviderHolder);
        errdefer allocator.destroy(holder);

        holder.* = ProviderHolder.fromConfig(allocator, config.default_provider, config.defaultProviderKey(), config.getProviderBaseUrl(config.default_provider));

        const provider_i = holder.provider();

        // MCP tools
        const mcp_tools: ?[]const tools_mod.Tool = if (config.mcp_servers.len > 0)
            mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
                log.warn("MCP init failed: {}", .{err});
                break :blk null;
            }
        else
            null;

        // Tools
        const tools = tools_mod.allTools(allocator, config.workspace_dir, .{
            .http_enabled = config.http_request.enabled,
            .browser_enabled = config.browser.enabled,
            .screenshot_enabled = true,
            .mcp_tools = mcp_tools,
            .agents = config.agents,
            .fallback_api_key = config.defaultProviderKey(),
            .tools_config = config.tools,
        }) catch &.{};
        errdefer if (tools.len > 0) allocator.free(tools);

        // Optional memory backend
        var mem_opt: ?memory_mod.Memory = null;
        const db_path = std.fs.path.joinZ(allocator, &.{ config.workspace_dir, "memory.db" }) catch null;
        defer if (db_path) |p| allocator.free(p);
        if (db_path) |p| {
            if (memory_mod.createMemory(allocator, config.memory.backend, p)) |mem| {
                mem_opt = mem;
            } else |_| {}
        }

        // Noop observer (heap for vtable stability)
        const noop_obs = try allocator.create(observability.NoopObserver);
        errdefer allocator.destroy(noop_obs);
        noop_obs.* = .{};
        const obs = noop_obs.observer();

        // Session manager
        const session_mgr = session_mod.SessionManager.init(allocator, config, provider_i, tools, mem_opt, obs);

        // Self — heap-allocated so pointers remain stable
        const self = try allocator.create(ChannelRuntime);
        self.* = .{
            .allocator = allocator,
            .session_mgr = session_mgr,
            .provider_holder = holder,
            .tools = tools,
            .mem = mem_opt,
            .noop_obs = noop_obs,
        };
        return self;
    }

    pub fn deinit(self: *ChannelRuntime) void {
        const alloc = self.allocator;
        self.session_mgr.deinit();
        if (self.tools.len > 0) alloc.free(self.tools);
        alloc.destroy(self.noop_obs);
        alloc.destroy(self.provider_holder);
        alloc.destroy(self);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// runDiscordLoop — consumer thread function
// ════════════════════════════════════════════════════════════════════════════

/// Extract message_id from bus message metadata JSON.
fn extractMessageId(allocator: std.mem.Allocator, metadata_json: ?[]const u8) ?[]const u8 {
    const md = metadata_json orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, md, .{}) catch return null;
    defer parsed.deinit();
    const mid_val = parsed.value.object.get("message_id") orelse return null;
    return switch (mid_val) {
        .string => |s| if (s.len > 0) (allocator.dupe(u8, s) catch null) else null,
        else => null,
    };
}

/// Thread-entry function for the Discord consumer loop.
/// Reads inbound messages from the bus, processes them through the session
/// manager, and sends replies via the Discord REST API.
/// Checks `loop_state.stop_requested` and `daemon.isShutdownRequested()`
/// each iteration; exits when the bus is closed (consumeInbound returns null).
pub fn runDiscordLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *DiscordLoopState,
    discord: *discord_mod.DiscordChannel,
    bus: *bus_mod.Bus,
) void {
    var evict_counter: u32 = 0;

    // Update activity timestamp at start
    loop_state.last_activity.store(std.time.timestamp(), .release);

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const maybe_msg = bus.consumeInbound();
        const msg = maybe_msg orelse break; // Bus closed — shutting down
        defer msg.deinit(allocator);

        // Update activity after each message
        loop_state.last_activity.store(std.time.timestamp(), .release);

        log.info("{s}: {s}", .{ msg.sender_id, msg.content });

        // Extract message_id from metadata for reaction support
        const message_id = extractMessageId(allocator, msg.metadata_json);
        defer if (message_id) |mid| allocator.free(mid);

        // Add eyes emoji reaction to indicate we're processing
        if (message_id) |mid| {
            discord.addReaction(msg.chat_id, mid, "%F0%9F%91%80");
        }

        const raw_reply = runtime.session_mgr.processMessageFrom(msg.session_key, msg.content, msg.sender_id) catch |err| {
            log.err("Agent error: {}", .{err});
            const err_msg: []const u8 = switch (err) {
                error.CurlFailed, error.CurlReadError, error.CurlWaitError => "Network error. Please try again.",
                error.OutOfMemory => "Out of memory.",
                else => "An error occurred. Try again.",
            };
            discord.sendMessage(msg.chat_id, err_msg) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
            continue;
        };

        // Check for conversation mode markers and strip them
        var reply: []const u8 = raw_reply;
        var reply_is_owned = false;
        if (std.mem.indexOf(u8, raw_reply, "[CONV_MODE:on]")) |pos| {
            discord.setConversationMode(msg.chat_id);
            const stripped = std.fmt.allocPrint(allocator, "{s}{s}", .{ raw_reply[0..pos], raw_reply[pos + "[CONV_MODE:on]".len ..] }) catch null;
            if (stripped) |s| {
                reply = s;
                reply_is_owned = true;
            }
        } else if (std.mem.indexOf(u8, raw_reply, "[CONV_MODE:off]")) |pos| {
            discord.clearConversationMode(msg.chat_id);
            const stripped = std.fmt.allocPrint(allocator, "{s}{s}", .{ raw_reply[0..pos], raw_reply[pos + "[CONV_MODE:off]".len ..] }) catch null;
            if (stripped) |s| {
                reply = s;
                reply_is_owned = true;
            }
        }
        defer {
            if (reply_is_owned) allocator.free(reply);
            allocator.free(raw_reply);
        }

        // Trim whitespace from stripped reply
        const trimmed_reply = std.mem.trim(u8, reply, " \t\r\n");

        if (trimmed_reply.len > 0) {
            discord.sendMessage(msg.chat_id, trimmed_reply) catch |err| {
                log.warn("Send error: {}", .{err});
            };
        }

        // Periodic session eviction
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }

        health.markComponentOk("discord");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "DiscordLoopState init defaults" {
    const state = DiscordLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.consumer_thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "DiscordLoopState stop_requested toggle" {
    var state = DiscordLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "DiscordLoopState last_activity update" {
    var state = DiscordLoopState.init();
    const before = state.last_activity.load(.acquire);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.last_activity.store(std.time.timestamp(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

test "extractMessageId from valid metadata" {
    const alloc = std.testing.allocator;
    const mid = extractMessageId(alloc, "{\"message_id\":\"12345\"}");
    try std.testing.expect(mid != null);
    try std.testing.expectEqualStrings("12345", mid.?);
    alloc.free(mid.?);
}

test "extractMessageId returns null for missing metadata" {
    try std.testing.expect(extractMessageId(std.testing.allocator, null) == null);
}

test "extractMessageId returns null for empty message_id" {
    try std.testing.expect(extractMessageId(std.testing.allocator, "{\"message_id\":\"\"}") == null);
}

test "extractMessageId returns null for invalid JSON" {
    try std.testing.expect(extractMessageId(std.testing.allocator, "not json") == null);
}

test "ProviderHolder tagged union fields" {
    // Compile-time check that ProviderHolder has expected variants
    try std.testing.expect(@hasField(ProviderHolder, "openrouter"));
    try std.testing.expect(@hasField(ProviderHolder, "anthropic"));
    try std.testing.expect(@hasField(ProviderHolder, "openai"));
    try std.testing.expect(@hasField(ProviderHolder, "gemini"));
    try std.testing.expect(@hasField(ProviderHolder, "ollama"));
    try std.testing.expect(@hasField(ProviderHolder, "compatible"));
    try std.testing.expect(@hasField(ProviderHolder, "openai_codex"));
}
