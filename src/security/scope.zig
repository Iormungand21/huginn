//! Secret scoping and per-workspace approval policy configuration.
//!
//! Provides:
//! - SecretScope: defines which workspace(s) or context(s) a secret is visible in
//! - WorkspaceApprovalPolicy: per-workspace override for approval thresholds
//! - Lookup helpers for resolving effective policy given a workspace ID

const std = @import("std");
const policy = @import("policy.zig");

const AutonomyLevel = policy.AutonomyLevel;
const CommandRiskLevel = policy.CommandRiskLevel;

// ── Secret Scope ──────────────────────────────────────────────────

/// Visibility scope for a stored secret (API key, token, credential).
/// Controls which workspace contexts may read a given secret.
pub const SecretScope = enum {
    /// Secret is available to all workspaces on this instance.
    global,
    /// Secret is restricted to one specific workspace (by workspace_id).
    workspace,
    /// Secret is restricted to a named group of workspaces.
    group,
    /// Secret is ephemeral — only available for the current session.
    session,

    pub fn toString(self: SecretScope) []const u8 {
        return switch (self) {
            .global => "global",
            .workspace => "workspace",
            .group => "group",
            .session => "session",
        };
    }

    pub fn fromString(s: []const u8) ?SecretScope {
        const map = std.StaticStringMap(SecretScope).initComptime(.{
            .{ "global", .global },
            .{ "workspace", .workspace },
            .{ "group", .group },
            .{ "session", .session },
        });
        return map.get(s);
    }

    /// Default scope for new secrets when not explicitly specified.
    pub fn default() SecretScope {
        return .workspace;
    }
};

/// A scoped secret binding: associates a secret name with its visibility scope
/// and optional workspace/group qualifier.
pub const ScopedSecret = struct {
    /// The secret name (key in the secret store, e.g. "OPENAI_API_KEY").
    name: []const u8,
    /// Visibility scope.
    scope: SecretScope = .workspace,
    /// Workspace or group identifier — required when scope is .workspace or .group,
    /// ignored for .global and .session.
    qualifier: ?[]const u8 = null,

    /// Check whether this secret is visible in the given workspace context.
    pub fn isVisibleIn(self: *const ScopedSecret, workspace_id: []const u8) bool {
        return switch (self.scope) {
            .global => true,
            .session => true,
            .workspace => if (self.qualifier) |q|
                std.mem.eql(u8, q, workspace_id)
            else
                false,
            // Group resolution is deferred to the caller / policy engine.
            // Skeleton returns false — callers should use resolveGroupMembership.
            .group => false,
        };
    }

    /// Serialize to a JSONL fragment into the provided buffer.
    /// Returns the written slice, or null if the buffer is too small.
    pub fn formatJsonLine(self: *const ScopedSecret, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"name\":\"") catch return null;
        w.writeAll(self.name) catch return null;
        w.writeAll("\",\"scope\":\"") catch return null;
        w.writeAll(self.scope.toString()) catch return null;
        w.writeByte('"') catch return null;
        if (self.qualifier) |q| {
            w.writeAll(",\"qualifier\":\"") catch return null;
            w.writeAll(q) catch return null;
            w.writeByte('"') catch return null;
        }
        w.writeByte('}') catch return null;
        return buf[0..stream.pos];
    }
};

// ── Workspace Approval Policy ─────────────────────────────────────

/// Per-workspace override for the approval policy. Allows workspaces to
/// tighten (never loosen beyond instance-level) security settings.
pub const WorkspaceApprovalPolicy = struct {
    /// Workspace identifier this policy applies to.
    workspace_id: []const u8,
    /// Override autonomy level — must not exceed the instance-level maximum.
    autonomy: ?AutonomyLevel = null,
    /// Override: require approval for medium-risk commands.
    require_approval_for_medium_risk: ?bool = null,
    /// Override: block all high-risk commands.
    block_high_risk_commands: ?bool = null,
    /// Override: max actions per hour for this workspace.
    max_actions_per_hour: ?u32 = null,
    /// Additional commands to allow beyond the instance allowlist.
    extra_allowed_commands: []const []const u8 = &.{},
    /// Additional paths this workspace may access.
    extra_allowed_paths: []const []const u8 = &.{},

    /// Resolve the effective autonomy level, clamping to the instance maximum.
    /// A workspace cannot escalate beyond the instance-level setting.
    pub fn effectiveAutonomy(
        self: *const WorkspaceApprovalPolicy,
        instance_level: AutonomyLevel,
    ) AutonomyLevel {
        const ws_level = self.autonomy orelse return instance_level;
        // Clamp: workspace cannot escalate beyond instance level.
        // Ordering: read_only(0) < supervised(1) < full(2)
        const ws_ord = autonomyOrd(ws_level);
        const inst_ord = autonomyOrd(instance_level);
        return if (ws_ord <= inst_ord) ws_level else instance_level;
    }

    /// Resolve effective approval requirement for medium-risk commands.
    /// Workspace can only tighten (require=true), never loosen.
    pub fn effectiveRequireApprovalMedium(
        self: *const WorkspaceApprovalPolicy,
        instance_setting: bool,
    ) bool {
        const ws_setting = self.require_approval_for_medium_risk orelse return instance_setting;
        // Tighten only: if instance requires, workspace cannot disable.
        return instance_setting or ws_setting;
    }

    /// Resolve effective high-risk blocking.
    /// Workspace can only tighten (block=true), never loosen.
    pub fn effectiveBlockHighRisk(
        self: *const WorkspaceApprovalPolicy,
        instance_setting: bool,
    ) bool {
        const ws_setting = self.block_high_risk_commands orelse return instance_setting;
        return instance_setting or ws_setting;
    }

    /// Resolve effective max actions per hour — workspace can only lower, not raise.
    pub fn effectiveMaxActionsPerHour(
        self: *const WorkspaceApprovalPolicy,
        instance_limit: u32,
    ) u32 {
        const ws_limit = self.max_actions_per_hour orelse return instance_limit;
        return @min(ws_limit, instance_limit);
    }
};

/// Ordinal for autonomy clamping (lower = more restrictive).
fn autonomyOrd(level: AutonomyLevel) u2 {
    return switch (level) {
        .read_only => 0,
        .supervised => 1,
        .full => 2,
    };
}

// ── Policy Lookup Helpers ─────────────────────────────────────────

/// Look up a workspace-specific policy from a policy list.
/// Returns null if no policy is configured for the given workspace.
/// Intended for later use by the enforcement pipeline.
pub fn findWorkspacePolicy(
    policies: []const WorkspaceApprovalPolicy,
    workspace_id: []const u8,
) ?*const WorkspaceApprovalPolicy {
    for (policies) |*p| {
        if (std.mem.eql(u8, p.workspace_id, workspace_id)) {
            return p;
        }
    }
    return null;
}

/// Look up a scoped secret by name and check visibility in a workspace.
/// Returns the secret if found and visible, null otherwise.
pub fn findVisibleSecret(
    secrets: []const ScopedSecret,
    name: []const u8,
    workspace_id: []const u8,
) ?*const ScopedSecret {
    for (secrets) |*s| {
        if (std.mem.eql(u8, s.name, name) and s.isVisibleIn(workspace_id)) {
            return s;
        }
    }
    return null;
}

/// Check if a secret name is visible in a workspace, without returning the secret.
pub fn isSecretVisible(
    secrets: []const ScopedSecret,
    name: []const u8,
    workspace_id: []const u8,
) bool {
    return findVisibleSecret(secrets, name, workspace_id) != null;
}

// ── Config Types ──────────────────────────────────────────────────

/// Configuration for secret scoping — embeddable in the top-level config.
/// Backward compatible: all fields have sensible defaults.
pub const SecretScopeConfig = struct {
    /// Default scope for newly stored secrets.
    default_scope: SecretScope = .workspace,
    /// Whether to enforce scope checks on secret reads.
    enforce: bool = false,
};

/// Configuration entry for a per-workspace approval policy override.
/// Parsed from the config JSON array.
pub const WorkspacePolicyConfig = struct {
    workspace_id: []const u8,
    autonomy: ?[]const u8 = null,
    require_approval_for_medium_risk: ?bool = null,
    block_high_risk_commands: ?bool = null,
    max_actions_per_hour: ?u32 = null,
    extra_allowed_commands: []const []const u8 = &.{},
    extra_allowed_paths: []const []const u8 = &.{},

    /// Convert to a resolved WorkspaceApprovalPolicy.
    pub fn resolve(self: *const WorkspacePolicyConfig) WorkspaceApprovalPolicy {
        const autonomy_level: ?AutonomyLevel = if (self.autonomy) |a|
            AutonomyLevel.fromString(a)
        else
            null;

        return .{
            .workspace_id = self.workspace_id,
            .autonomy = autonomy_level,
            .require_approval_for_medium_risk = self.require_approval_for_medium_risk,
            .block_high_risk_commands = self.block_high_risk_commands,
            .max_actions_per_hour = self.max_actions_per_hour,
            .extra_allowed_commands = self.extra_allowed_commands,
            .extra_allowed_paths = self.extra_allowed_paths,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "SecretScope default is workspace" {
    try std.testing.expectEqual(SecretScope.workspace, SecretScope.default());
}

test "SecretScope toString roundtrip" {
    try std.testing.expectEqualStrings("global", SecretScope.global.toString());
    try std.testing.expectEqualStrings("workspace", SecretScope.workspace.toString());
    try std.testing.expectEqualStrings("group", SecretScope.group.toString());
    try std.testing.expectEqualStrings("session", SecretScope.session.toString());
}

test "SecretScope fromString roundtrip" {
    try std.testing.expectEqual(SecretScope.global, SecretScope.fromString("global").?);
    try std.testing.expectEqual(SecretScope.workspace, SecretScope.fromString("workspace").?);
    try std.testing.expectEqual(SecretScope.group, SecretScope.fromString("group").?);
    try std.testing.expectEqual(SecretScope.session, SecretScope.fromString("session").?);
    try std.testing.expect(SecretScope.fromString("invalid") == null);
    try std.testing.expect(SecretScope.fromString("") == null);
}

test "ScopedSecret global is visible everywhere" {
    const s = ScopedSecret{ .name = "API_KEY", .scope = .global };
    try std.testing.expect(s.isVisibleIn("ws-1"));
    try std.testing.expect(s.isVisibleIn("ws-2"));
    try std.testing.expect(s.isVisibleIn(""));
}

test "ScopedSecret workspace scoped visible only in matching workspace" {
    const s = ScopedSecret{ .name = "DB_PASS", .scope = .workspace, .qualifier = "ws-1" };
    try std.testing.expect(s.isVisibleIn("ws-1"));
    try std.testing.expect(!s.isVisibleIn("ws-2"));
    try std.testing.expect(!s.isVisibleIn(""));
}

test "ScopedSecret workspace scoped without qualifier is invisible" {
    const s = ScopedSecret{ .name = "DB_PASS", .scope = .workspace, .qualifier = null };
    try std.testing.expect(!s.isVisibleIn("ws-1"));
}

test "ScopedSecret session scoped is visible everywhere" {
    const s = ScopedSecret{ .name = "TEMP_TOKEN", .scope = .session };
    try std.testing.expect(s.isVisibleIn("ws-1"));
    try std.testing.expect(s.isVisibleIn("ws-2"));
}

test "ScopedSecret group scoped returns false (skeleton)" {
    const s = ScopedSecret{ .name = "GROUP_KEY", .scope = .group, .qualifier = "team-a" };
    // Group resolution is deferred — skeleton always returns false.
    try std.testing.expect(!s.isVisibleIn("ws-1"));
}

test "ScopedSecret formatJsonLine basic" {
    const s = ScopedSecret{ .name = "API_KEY", .scope = .global };
    var buf: [256]u8 = undefined;
    const json = s.formatJsonLine(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"API_KEY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scope\":\"global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "qualifier") == null);
}

test "ScopedSecret formatJsonLine with qualifier" {
    const s = ScopedSecret{ .name = "DB_PASS", .scope = .workspace, .qualifier = "ws-1" };
    var buf: [256]u8 = undefined;
    const json = s.formatJsonLine(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"DB_PASS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scope\":\"workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"qualifier\":\"ws-1\"") != null);
}

test "ScopedSecret formatJsonLine returns null on tiny buffer" {
    const s = ScopedSecret{ .name = "API_KEY", .scope = .global };
    var buf: [5]u8 = undefined;
    try std.testing.expect(s.formatJsonLine(&buf) == null);
}

test "WorkspaceApprovalPolicy effectiveAutonomy clamps to instance level" {
    // Instance is supervised — workspace cannot escalate to full.
    const ws = WorkspaceApprovalPolicy{
        .workspace_id = "ws-1",
        .autonomy = .full,
    };
    try std.testing.expectEqual(AutonomyLevel.supervised, ws.effectiveAutonomy(.supervised));

    // Instance is full — workspace can set supervised (more restrictive).
    const ws2 = WorkspaceApprovalPolicy{
        .workspace_id = "ws-2",
        .autonomy = .supervised,
    };
    try std.testing.expectEqual(AutonomyLevel.supervised, ws2.effectiveAutonomy(.full));

    // Instance is full — workspace can set read_only.
    const ws3 = WorkspaceApprovalPolicy{
        .workspace_id = "ws-3",
        .autonomy = .read_only,
    };
    try std.testing.expectEqual(AutonomyLevel.read_only, ws3.effectiveAutonomy(.full));
}

test "WorkspaceApprovalPolicy effectiveAutonomy uses instance when no override" {
    const ws = WorkspaceApprovalPolicy{
        .workspace_id = "ws-1",
        .autonomy = null,
    };
    try std.testing.expectEqual(AutonomyLevel.supervised, ws.effectiveAutonomy(.supervised));
    try std.testing.expectEqual(AutonomyLevel.full, ws.effectiveAutonomy(.full));
}

test "WorkspaceApprovalPolicy effectiveRequireApprovalMedium tightens only" {
    const ws = WorkspaceApprovalPolicy{
        .workspace_id = "ws-1",
        .require_approval_for_medium_risk = false,
    };
    // Instance requires approval — workspace cannot disable.
    try std.testing.expect(ws.effectiveRequireApprovalMedium(true));

    // Instance does not require — workspace can enable.
    const ws2 = WorkspaceApprovalPolicy{
        .workspace_id = "ws-2",
        .require_approval_for_medium_risk = true,
    };
    try std.testing.expect(ws2.effectiveRequireApprovalMedium(false));
}

test "WorkspaceApprovalPolicy effectiveRequireApprovalMedium uses instance when null" {
    const ws = WorkspaceApprovalPolicy{
        .workspace_id = "ws-1",
    };
    try std.testing.expect(ws.effectiveRequireApprovalMedium(true));
    try std.testing.expect(!ws.effectiveRequireApprovalMedium(false));
}

test "WorkspaceApprovalPolicy effectiveBlockHighRisk tightens only" {
    const ws = WorkspaceApprovalPolicy{
        .workspace_id = "ws-1",
        .block_high_risk_commands = false,
    };
    // Instance blocks — workspace cannot unblock.
    try std.testing.expect(ws.effectiveBlockHighRisk(true));

    const ws2 = WorkspaceApprovalPolicy{
        .workspace_id = "ws-2",
        .block_high_risk_commands = true,
    };
    // Instance does not block — workspace can enable blocking.
    try std.testing.expect(ws2.effectiveBlockHighRisk(false));
}

test "WorkspaceApprovalPolicy effectiveBlockHighRisk uses instance when null" {
    const ws = WorkspaceApprovalPolicy{ .workspace_id = "ws-1" };
    try std.testing.expect(ws.effectiveBlockHighRisk(true));
    try std.testing.expect(!ws.effectiveBlockHighRisk(false));
}

test "WorkspaceApprovalPolicy effectiveMaxActionsPerHour takes minimum" {
    const ws = WorkspaceApprovalPolicy{
        .workspace_id = "ws-1",
        .max_actions_per_hour = 10,
    };
    // Instance allows 20, workspace lowers to 10.
    try std.testing.expectEqual(@as(u32, 10), ws.effectiveMaxActionsPerHour(20));
    // Instance allows 5, workspace wants 10 — clamped to 5.
    try std.testing.expectEqual(@as(u32, 5), ws.effectiveMaxActionsPerHour(5));
}

test "WorkspaceApprovalPolicy effectiveMaxActionsPerHour uses instance when null" {
    const ws = WorkspaceApprovalPolicy{ .workspace_id = "ws-1" };
    try std.testing.expectEqual(@as(u32, 20), ws.effectiveMaxActionsPerHour(20));
}

test "findWorkspacePolicy returns matching policy" {
    const policies = [_]WorkspaceApprovalPolicy{
        .{ .workspace_id = "ws-1", .autonomy = .read_only },
        .{ .workspace_id = "ws-2", .autonomy = .full },
    };
    const found = findWorkspacePolicy(&policies, "ws-2").?;
    try std.testing.expectEqualStrings("ws-2", found.workspace_id);
    try std.testing.expectEqual(AutonomyLevel.full, found.autonomy.?);
}

test "findWorkspacePolicy returns null when not found" {
    const policies = [_]WorkspaceApprovalPolicy{
        .{ .workspace_id = "ws-1" },
    };
    try std.testing.expect(findWorkspacePolicy(&policies, "ws-999") == null);
}

test "findWorkspacePolicy handles empty list" {
    const policies = [_]WorkspaceApprovalPolicy{};
    try std.testing.expect(findWorkspacePolicy(&policies, "ws-1") == null);
}

test "findVisibleSecret returns visible secret" {
    const secrets = [_]ScopedSecret{
        .{ .name = "GLOBAL_KEY", .scope = .global },
        .{ .name = "WS1_KEY", .scope = .workspace, .qualifier = "ws-1" },
        .{ .name = "WS2_KEY", .scope = .workspace, .qualifier = "ws-2" },
    };
    const found = findVisibleSecret(&secrets, "WS1_KEY", "ws-1").?;
    try std.testing.expectEqualStrings("WS1_KEY", found.name);
}

test "findVisibleSecret skips invisible secret" {
    const secrets = [_]ScopedSecret{
        .{ .name = "WS1_KEY", .scope = .workspace, .qualifier = "ws-1" },
    };
    try std.testing.expect(findVisibleSecret(&secrets, "WS1_KEY", "ws-2") == null);
}

test "findVisibleSecret finds global secret from any workspace" {
    const secrets = [_]ScopedSecret{
        .{ .name = "SHARED", .scope = .global },
    };
    try std.testing.expect(findVisibleSecret(&secrets, "SHARED", "ws-1") != null);
    try std.testing.expect(findVisibleSecret(&secrets, "SHARED", "ws-99") != null);
}

test "findVisibleSecret returns null for unknown name" {
    const secrets = [_]ScopedSecret{
        .{ .name = "API_KEY", .scope = .global },
    };
    try std.testing.expect(findVisibleSecret(&secrets, "MISSING", "ws-1") == null);
}

test "isSecretVisible convenience wrapper" {
    const secrets = [_]ScopedSecret{
        .{ .name = "API_KEY", .scope = .global },
        .{ .name = "DB_PASS", .scope = .workspace, .qualifier = "ws-1" },
    };
    try std.testing.expect(isSecretVisible(&secrets, "API_KEY", "ws-2"));
    try std.testing.expect(isSecretVisible(&secrets, "DB_PASS", "ws-1"));
    try std.testing.expect(!isSecretVisible(&secrets, "DB_PASS", "ws-2"));
    try std.testing.expect(!isSecretVisible(&secrets, "MISSING", "ws-1"));
}

test "WorkspacePolicyConfig resolve converts string to AutonomyLevel" {
    const cfg = WorkspacePolicyConfig{
        .workspace_id = "ws-1",
        .autonomy = "supervised",
        .require_approval_for_medium_risk = true,
        .max_actions_per_hour = 10,
    };
    const resolved = cfg.resolve();
    try std.testing.expectEqualStrings("ws-1", resolved.workspace_id);
    try std.testing.expectEqual(AutonomyLevel.supervised, resolved.autonomy.?);
    try std.testing.expect(resolved.require_approval_for_medium_risk.?);
    try std.testing.expectEqual(@as(u32, 10), resolved.max_actions_per_hour.?);
}

test "WorkspacePolicyConfig resolve with invalid autonomy yields null" {
    const cfg = WorkspacePolicyConfig{
        .workspace_id = "ws-1",
        .autonomy = "invalid_level",
    };
    const resolved = cfg.resolve();
    try std.testing.expect(resolved.autonomy == null);
}

test "WorkspacePolicyConfig resolve with null autonomy yields null" {
    const cfg = WorkspacePolicyConfig{
        .workspace_id = "ws-1",
        .autonomy = null,
    };
    const resolved = cfg.resolve();
    try std.testing.expect(resolved.autonomy == null);
}

test "SecretScopeConfig has backward-compatible defaults" {
    const cfg = SecretScopeConfig{};
    try std.testing.expectEqual(SecretScope.workspace, cfg.default_scope);
    try std.testing.expect(!cfg.enforce);
}

test "autonomyOrd ordering" {
    try std.testing.expect(autonomyOrd(.read_only) < autonomyOrd(.supervised));
    try std.testing.expect(autonomyOrd(.supervised) < autonomyOrd(.full));
}
