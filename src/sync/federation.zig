//! Federated task routing handshake and heartbeat message flow.
//!
//! Defines the types and state transitions for establishing and maintaining
//! connections between sync peers (e.g. huginn <-> muninn):
//!
//!   - **PeerState** — connection lifecycle: disconnected -> handshake_pending
//!     -> connected -> degraded -> offline (with valid transitions enforced)
//!   - **HandshakeRequest / HandshakeResponse** — initial capability exchange
//!   - **Heartbeat** — periodic liveness signal with sequence tracking
//!   - **PeerInfo** — tracks a known peer's state and heartbeat history
//!   - **HeartbeatConfig** — tunable intervals and thresholds
//!
//! No actual transport wiring — this module provides the message types and
//! state machine that a future transport layer will drive.

const std = @import("std");
const types = @import("types.zig");

const NodeId = types.NodeId;
const SequenceNum = types.SequenceNum;
const Timestamp = types.Timestamp;
const SCHEMA_VERSION = types.SCHEMA_VERSION;

// ── Peer connection state ─────────────────────────────────────────

/// Connection lifecycle state for a sync peer.
pub const PeerState = enum {
    /// No connection established. Initial state.
    disconnected,
    /// Handshake request sent, awaiting response.
    handshake_pending,
    /// Handshake complete, heartbeats flowing normally.
    connected,
    /// Heartbeat(s) missed but not yet timed out.
    degraded,
    /// Peer considered unreachable after exceeding heartbeat timeout.
    offline,

    pub fn toString(self: PeerState) []const u8 {
        return switch (self) {
            .disconnected => "disconnected",
            .handshake_pending => "handshake_pending",
            .connected => "connected",
            .degraded => "degraded",
            .offline => "offline",
        };
    }

    pub fn fromString(s: []const u8) ?PeerState {
        if (std.mem.eql(u8, s, "disconnected")) return .disconnected;
        if (std.mem.eql(u8, s, "handshake_pending")) return .handshake_pending;
        if (std.mem.eql(u8, s, "connected")) return .connected;
        if (std.mem.eql(u8, s, "degraded")) return .degraded;
        if (std.mem.eql(u8, s, "offline")) return .offline;
        return null;
    }

    /// Check whether a transition from this state to `target` is valid.
    ///
    /// Valid transitions:
    ///   disconnected     -> handshake_pending  (initiating handshake)
    ///   handshake_pending -> connected          (handshake accepted)
    ///   handshake_pending -> disconnected       (handshake rejected/timeout)
    ///   connected        -> degraded            (heartbeat missed)
    ///   connected        -> disconnected        (clean shutdown)
    ///   degraded         -> connected           (heartbeat recovered)
    ///   degraded         -> offline             (timeout exceeded)
    ///   degraded         -> disconnected        (clean shutdown)
    ///   offline          -> disconnected        (reset for reconnect)
    pub fn canTransitionTo(self: PeerState, target: PeerState) bool {
        return switch (self) {
            .disconnected => target == .handshake_pending,
            .handshake_pending => target == .connected or target == .disconnected,
            .connected => target == .degraded or target == .disconnected,
            .degraded => target == .connected or target == .offline or target == .disconnected,
            .offline => target == .disconnected,
        };
    }
};

// ── Handshake messages ────────────────────────────────────────────

/// Outcome of a handshake attempt.
pub const HandshakeResult = enum {
    /// Handshake accepted — peer is compatible.
    accepted,
    /// Handshake rejected — peer declined (e.g. unknown node, policy).
    rejected,
    /// Schema version mismatch — peers cannot interoperate.
    version_mismatch,

    pub fn toString(self: HandshakeResult) []const u8 {
        return switch (self) {
            .accepted => "accepted",
            .rejected => "rejected",
            .version_mismatch => "version_mismatch",
        };
    }

    pub fn fromString(s: []const u8) ?HandshakeResult {
        if (std.mem.eql(u8, s, "accepted")) return .accepted;
        if (std.mem.eql(u8, s, "rejected")) return .rejected;
        if (std.mem.eql(u8, s, "version_mismatch")) return .version_mismatch;
        return null;
    }
};

/// Sent by the initiating node to begin a sync session.
pub const HandshakeRequest = struct {
    /// Identity of the node initiating the handshake.
    source_node: NodeId,
    /// Protocol schema version the initiator speaks.
    schema_version: u32 = SCHEMA_VERSION,
    /// Wall-clock timestamp when the request was created.
    timestamp: Timestamp,
    /// Last sequence number this node has seen from the target peer
    /// (0 if first contact). Allows the responder to know where to
    /// resume delta replay.
    last_seen_sequence: SequenceNum = 0,

    pub fn validate(self: HandshakeRequest) bool {
        return self.source_node.validate() and self.schema_version > 0;
    }
};

/// Sent by the responder to accept or reject a handshake.
pub const HandshakeResponse = struct {
    /// Identity of the responding node.
    source_node: NodeId,
    /// Protocol schema version the responder speaks.
    schema_version: u32 = SCHEMA_VERSION,
    /// Wall-clock timestamp of the response.
    timestamp: Timestamp,
    /// Outcome of the handshake attempt.
    result: HandshakeResult,
    /// Human-readable reason when result is not accepted.
    reason: ?[]const u8 = null,
    /// Last sequence the responder has seen from the initiator
    /// (for bidirectional cursor exchange).
    last_seen_sequence: SequenceNum = 0,

    pub fn validate(self: HandshakeResponse) bool {
        return self.source_node.validate() and self.schema_version > 0;
    }
};

/// Evaluate whether two nodes can interoperate based on schema versions.
pub fn checkVersionCompatibility(local_version: u32, remote_version: u32) HandshakeResult {
    if (local_version == remote_version) return .accepted;
    return .version_mismatch;
}

// ── Heartbeat messages ────────────────────────────────────────────

/// Periodic liveness signal exchanged between connected peers.
pub const Heartbeat = struct {
    /// Identity of the node sending the heartbeat.
    source_node: NodeId,
    /// Wall-clock timestamp when the heartbeat was sent.
    timestamp: Timestamp,
    /// Current sequence number at the sending node (allows the receiver
    /// to detect if it has fallen behind on delta consumption).
    sequence: SequenceNum,
    /// Uptime of the sending node in milliseconds (informational).
    uptime_ms: u64 = 0,

    pub fn validate(self: Heartbeat) bool {
        return self.source_node.validate();
    }
};

/// Tunable parameters for the heartbeat protocol.
pub const HeartbeatConfig = struct {
    /// How often to send heartbeats (ms).
    interval_ms: u64 = 30_000,
    /// How many consecutive missed heartbeats before entering degraded state.
    degraded_after_missed: u32 = 2,
    /// How many consecutive missed heartbeats before entering offline state.
    offline_after_missed: u32 = 5,

    /// Compute the wall-clock deadline for the degraded transition.
    pub fn degradedTimeoutMs(self: HeartbeatConfig) u64 {
        return self.interval_ms * @as(u64, self.degraded_after_missed);
    }

    /// Compute the wall-clock deadline for the offline transition.
    pub fn offlineTimeoutMs(self: HeartbeatConfig) u64 {
        return self.interval_ms * @as(u64, self.offline_after_missed);
    }
};

// ── Peer tracker ──────────────────────────────────────────────────

/// Tracks the known state of a sync peer.
pub const PeerInfo = struct {
    /// The remote node being tracked.
    node: NodeId,
    /// Current connection state.
    state: PeerState = .disconnected,
    /// Wall-clock timestamp of the last received heartbeat (0 = never).
    last_heartbeat_ts: Timestamp = 0,
    /// Count of consecutive missed heartbeat intervals.
    missed_heartbeats: u32 = 0,
    /// Wall-clock timestamp when the connection was established (0 = never).
    connected_at: Timestamp = 0,
    /// The last sequence number received from this peer.
    last_received_sequence: SequenceNum = 0,

    /// Attempt a state transition. Returns true on success, false if invalid.
    pub fn transitionTo(self: *PeerInfo, new_state: PeerState) bool {
        if (!self.state.canTransitionTo(new_state)) return false;
        self.state = new_state;
        return true;
    }

    /// Record a successful heartbeat reception.
    pub fn recordHeartbeat(self: *PeerInfo, hb: Heartbeat) void {
        self.last_heartbeat_ts = hb.timestamp;
        self.missed_heartbeats = 0;
        self.last_received_sequence = hb.sequence;
        // If degraded, recover to connected
        if (self.state == .degraded) {
            self.state = .connected;
        }
    }

    /// Record a missed heartbeat interval. Returns the new state after
    /// applying threshold checks from the provided config.
    pub fn recordMissedHeartbeat(self: *PeerInfo, config: HeartbeatConfig) PeerState {
        self.missed_heartbeats += 1;
        if (self.state == .connected and self.missed_heartbeats >= config.degraded_after_missed) {
            self.state = .degraded;
        }
        if (self.state == .degraded and self.missed_heartbeats >= config.offline_after_missed) {
            self.state = .offline;
        }
        return self.state;
    }

    /// Reset peer to disconnected state for a fresh reconnection attempt.
    pub fn reset(self: *PeerInfo) void {
        self.state = .disconnected;
        self.last_heartbeat_ts = 0;
        self.missed_heartbeats = 0;
        self.connected_at = 0;
        self.last_received_sequence = 0;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

// ── PeerState tests ───────────────────────────────────────────────

test "PeerState toString roundtrip" {
    try testing.expectEqualStrings("disconnected", PeerState.disconnected.toString());
    try testing.expectEqualStrings("handshake_pending", PeerState.handshake_pending.toString());
    try testing.expectEqualStrings("connected", PeerState.connected.toString());
    try testing.expectEqualStrings("degraded", PeerState.degraded.toString());
    try testing.expectEqualStrings("offline", PeerState.offline.toString());
}

test "PeerState fromString valid" {
    try testing.expect(PeerState.fromString("disconnected").? == .disconnected);
    try testing.expect(PeerState.fromString("handshake_pending").? == .handshake_pending);
    try testing.expect(PeerState.fromString("connected").? == .connected);
    try testing.expect(PeerState.fromString("degraded").? == .degraded);
    try testing.expect(PeerState.fromString("offline").? == .offline);
}

test "PeerState fromString invalid returns null" {
    try testing.expect(PeerState.fromString("bogus") == null);
    try testing.expect(PeerState.fromString("") == null);
}

test "PeerState valid transitions" {
    // disconnected -> handshake_pending
    try testing.expect(PeerState.disconnected.canTransitionTo(.handshake_pending));
    // handshake_pending -> connected
    try testing.expect(PeerState.handshake_pending.canTransitionTo(.connected));
    // handshake_pending -> disconnected (rejected)
    try testing.expect(PeerState.handshake_pending.canTransitionTo(.disconnected));
    // connected -> degraded
    try testing.expect(PeerState.connected.canTransitionTo(.degraded));
    // connected -> disconnected (clean shutdown)
    try testing.expect(PeerState.connected.canTransitionTo(.disconnected));
    // degraded -> connected (recovery)
    try testing.expect(PeerState.degraded.canTransitionTo(.connected));
    // degraded -> offline
    try testing.expect(PeerState.degraded.canTransitionTo(.offline));
    // degraded -> disconnected (clean shutdown)
    try testing.expect(PeerState.degraded.canTransitionTo(.disconnected));
    // offline -> disconnected (reset)
    try testing.expect(PeerState.offline.canTransitionTo(.disconnected));
}

test "PeerState invalid transitions" {
    // Can't skip handshake
    try testing.expect(!PeerState.disconnected.canTransitionTo(.connected));
    try testing.expect(!PeerState.disconnected.canTransitionTo(.degraded));
    try testing.expect(!PeerState.disconnected.canTransitionTo(.offline));
    // Can't go backwards from connected to handshake
    try testing.expect(!PeerState.connected.canTransitionTo(.handshake_pending));
    // Can't go directly from connected to offline
    try testing.expect(!PeerState.connected.canTransitionTo(.offline));
    // Can't go from offline to connected directly
    try testing.expect(!PeerState.offline.canTransitionTo(.connected));
    try testing.expect(!PeerState.offline.canTransitionTo(.handshake_pending));
    // Self-transitions are not valid
    try testing.expect(!PeerState.disconnected.canTransitionTo(.disconnected));
    try testing.expect(!PeerState.connected.canTransitionTo(.connected));
}

// ── Handshake tests ───────────────────────────────────────────────

test "HandshakeRequest validate" {
    const valid = HandshakeRequest{
        .source_node = .{ .id = "huginn-pi5" },
        .timestamp = 1700000000000,
    };
    try testing.expect(valid.validate());

    const empty_node = HandshakeRequest{
        .source_node = .{ .id = "" },
        .timestamp = 1700000000000,
    };
    try testing.expect(!empty_node.validate());
}

test "HandshakeRequest defaults" {
    const req = HandshakeRequest{
        .source_node = .{ .id = "node-a" },
        .timestamp = 1700000000000,
    };
    try testing.expectEqual(SCHEMA_VERSION, req.schema_version);
    try testing.expectEqual(@as(SequenceNum, 0), req.last_seen_sequence);
}

test "HandshakeResponse validate" {
    const valid = HandshakeResponse{
        .source_node = .{ .id = "muninn-desktop" },
        .timestamp = 1700000000000,
        .result = .accepted,
    };
    try testing.expect(valid.validate());

    const empty_node = HandshakeResponse{
        .source_node = .{ .id = "" },
        .timestamp = 1700000000000,
        .result = .rejected,
    };
    try testing.expect(!empty_node.validate());
}

test "HandshakeResponse with rejection reason" {
    const resp = HandshakeResponse{
        .source_node = .{ .id = "muninn" },
        .timestamp = 1700000000000,
        .result = .rejected,
        .reason = "unknown node identity",
    };
    try testing.expect(resp.result == .rejected);
    try testing.expectEqualStrings("unknown node identity", resp.reason.?);
}

test "HandshakeResult toString roundtrip" {
    try testing.expectEqualStrings("accepted", HandshakeResult.accepted.toString());
    try testing.expectEqualStrings("rejected", HandshakeResult.rejected.toString());
    try testing.expectEqualStrings("version_mismatch", HandshakeResult.version_mismatch.toString());
}

test "HandshakeResult fromString" {
    try testing.expect(HandshakeResult.fromString("accepted").? == .accepted);
    try testing.expect(HandshakeResult.fromString("rejected").? == .rejected);
    try testing.expect(HandshakeResult.fromString("version_mismatch").? == .version_mismatch);
    try testing.expect(HandshakeResult.fromString("bogus") == null);
}

test "checkVersionCompatibility" {
    try testing.expect(checkVersionCompatibility(1, 1) == .accepted);
    try testing.expect(checkVersionCompatibility(1, 2) == .version_mismatch);
    try testing.expect(checkVersionCompatibility(2, 1) == .version_mismatch);
}

// ── Heartbeat tests ───────────────────────────────────────────────

test "Heartbeat validate" {
    const valid = Heartbeat{
        .source_node = .{ .id = "huginn" },
        .timestamp = 1700000000000,
        .sequence = 42,
    };
    try testing.expect(valid.validate());

    const invalid = Heartbeat{
        .source_node = .{ .id = "" },
        .timestamp = 1700000000000,
        .sequence = 1,
    };
    try testing.expect(!invalid.validate());
}

test "Heartbeat defaults" {
    const hb = Heartbeat{
        .source_node = .{ .id = "node" },
        .timestamp = 1000,
        .sequence = 1,
    };
    try testing.expectEqual(@as(u64, 0), hb.uptime_ms);
}

test "HeartbeatConfig defaults" {
    const config = HeartbeatConfig{};
    try testing.expectEqual(@as(u64, 30_000), config.interval_ms);
    try testing.expectEqual(@as(u32, 2), config.degraded_after_missed);
    try testing.expectEqual(@as(u32, 5), config.offline_after_missed);
}

test "HeartbeatConfig timeout calculations" {
    const config = HeartbeatConfig{
        .interval_ms = 10_000,
        .degraded_after_missed = 3,
        .offline_after_missed = 6,
    };
    try testing.expectEqual(@as(u64, 30_000), config.degradedTimeoutMs());
    try testing.expectEqual(@as(u64, 60_000), config.offlineTimeoutMs());
}

// ── PeerInfo tests ────────────────────────────────────────────────

test "PeerInfo defaults" {
    const peer = PeerInfo{ .node = .{ .id = "remote-node" } };
    try testing.expect(peer.state == .disconnected);
    try testing.expectEqual(@as(Timestamp, 0), peer.last_heartbeat_ts);
    try testing.expectEqual(@as(u32, 0), peer.missed_heartbeats);
    try testing.expectEqual(@as(Timestamp, 0), peer.connected_at);
    try testing.expectEqual(@as(SequenceNum, 0), peer.last_received_sequence);
}

test "PeerInfo transitionTo valid" {
    var peer = PeerInfo{ .node = .{ .id = "muninn" } };
    try testing.expect(peer.transitionTo(.handshake_pending));
    try testing.expect(peer.state == .handshake_pending);
    try testing.expect(peer.transitionTo(.connected));
    try testing.expect(peer.state == .connected);
}

test "PeerInfo transitionTo invalid" {
    var peer = PeerInfo{ .node = .{ .id = "muninn" } };
    // Can't go straight to connected from disconnected
    try testing.expect(!peer.transitionTo(.connected));
    try testing.expect(peer.state == .disconnected);
}

test "PeerInfo recordHeartbeat updates state" {
    var peer = PeerInfo{ .node = .{ .id = "muninn" }, .state = .connected };
    peer.missed_heartbeats = 1;
    const hb = Heartbeat{
        .source_node = .{ .id = "muninn" },
        .timestamp = 1700000000000,
        .sequence = 42,
    };
    peer.recordHeartbeat(hb);
    try testing.expectEqual(@as(Timestamp, 1700000000000), peer.last_heartbeat_ts);
    try testing.expectEqual(@as(u32, 0), peer.missed_heartbeats);
    try testing.expectEqual(@as(SequenceNum, 42), peer.last_received_sequence);
}

test "PeerInfo recordHeartbeat recovers from degraded" {
    var peer = PeerInfo{
        .node = .{ .id = "muninn" },
        .state = .degraded,
        .missed_heartbeats = 3,
    };
    const hb = Heartbeat{
        .source_node = .{ .id = "muninn" },
        .timestamp = 1700000000000,
        .sequence = 10,
    };
    peer.recordHeartbeat(hb);
    try testing.expect(peer.state == .connected);
    try testing.expectEqual(@as(u32, 0), peer.missed_heartbeats);
}

test "PeerInfo recordMissedHeartbeat transitions to degraded" {
    var peer = PeerInfo{ .node = .{ .id = "muninn" }, .state = .connected };
    const config = HeartbeatConfig{
        .interval_ms = 10_000,
        .degraded_after_missed = 2,
        .offline_after_missed = 5,
    };
    // First miss — still connected
    try testing.expect(peer.recordMissedHeartbeat(config) == .connected);
    try testing.expectEqual(@as(u32, 1), peer.missed_heartbeats);
    // Second miss — transitions to degraded
    try testing.expect(peer.recordMissedHeartbeat(config) == .degraded);
    try testing.expectEqual(@as(u32, 2), peer.missed_heartbeats);
}

test "PeerInfo recordMissedHeartbeat transitions from degraded to offline" {
    var peer = PeerInfo{
        .node = .{ .id = "muninn" },
        .state = .degraded,
        .missed_heartbeats = 4,
    };
    const config = HeartbeatConfig{
        .interval_ms = 10_000,
        .degraded_after_missed = 2,
        .offline_after_missed = 5,
    };
    // Fifth miss — transitions to offline
    try testing.expect(peer.recordMissedHeartbeat(config) == .offline);
    try testing.expectEqual(@as(u32, 5), peer.missed_heartbeats);
}

test "PeerInfo full lifecycle: connect -> degrade -> offline -> reset" {
    var peer = PeerInfo{ .node = .{ .id = "muninn" } };
    const config = HeartbeatConfig{
        .interval_ms = 5_000,
        .degraded_after_missed = 1,
        .offline_after_missed = 3,
    };

    // Connect
    try testing.expect(peer.transitionTo(.handshake_pending));
    try testing.expect(peer.transitionTo(.connected));
    peer.connected_at = 1000;

    // Receive a heartbeat
    peer.recordHeartbeat(.{
        .source_node = .{ .id = "muninn" },
        .timestamp = 2000,
        .sequence = 1,
    });
    try testing.expect(peer.state == .connected);

    // Miss heartbeats -> degraded
    _ = peer.recordMissedHeartbeat(config);
    try testing.expect(peer.state == .degraded);

    // Miss more -> offline
    _ = peer.recordMissedHeartbeat(config);
    _ = peer.recordMissedHeartbeat(config);
    try testing.expect(peer.state == .offline);

    // Reset for reconnection
    peer.reset();
    try testing.expect(peer.state == .disconnected);
    try testing.expectEqual(@as(Timestamp, 0), peer.last_heartbeat_ts);
    try testing.expectEqual(@as(u32, 0), peer.missed_heartbeats);
    try testing.expectEqual(@as(Timestamp, 0), peer.connected_at);
}

test "PeerInfo reset clears all tracking fields" {
    var peer = PeerInfo{
        .node = .{ .id = "muninn" },
        .state = .offline,
        .last_heartbeat_ts = 9999,
        .missed_heartbeats = 10,
        .connected_at = 5000,
        .last_received_sequence = 42,
    };
    peer.reset();
    try testing.expect(peer.state == .disconnected);
    try testing.expectEqual(@as(Timestamp, 0), peer.last_heartbeat_ts);
    try testing.expectEqual(@as(u32, 0), peer.missed_heartbeats);
    try testing.expectEqual(@as(Timestamp, 0), peer.connected_at);
    try testing.expectEqual(@as(SequenceNum, 0), peer.last_received_sequence);
    // node identity is preserved
    try testing.expectEqualStrings("muninn", peer.node.id);
}
