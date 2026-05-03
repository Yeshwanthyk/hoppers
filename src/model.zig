const std = @import("std");

pub const AgentKind = enum {
    claude,
    codex,
    pi,
    marvin,
    unknown,

    pub fn label(self: AgentKind) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .pi => "pi",
            .marvin => "marvin",
            .unknown => "unknown",
        };
    }
};

pub const AgentStatus = enum {
    idle,
    running,
    waiting,
    done,
    failed,
    stale,

    pub fn label(self: AgentStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .waiting => "waiting",
            .done => "done",
            .failed => "failed",
            .stale => "stale",
        };
    }
};

pub const Project = struct {
    id: []const u8,
    name: []const u8,
    root: []const u8,
    pinned: bool = false,
};

pub const TmuxPane = struct {
    session_name: []const u8,
    window_id: []const u8,
    pane_id: []const u8,
    pane_pid: u32,
    current_command: []const u8,
    start_command: []const u8,
    current_path: []const u8,
    title: []const u8,
};

pub const AgentInstance = struct {
    id: []const u8,
    kind: AgentKind,
    status: AgentStatus,
    project_id: []const u8,
    session_name: []const u8,
    window_id: []const u8,
    pane_id: []const u8,
    title: []const u8,
    unseen: bool = false,
    last_seen_ms: i64 = 0,
};

pub const CockpitItem = struct {
    rank: usize,
    priority: i32,
    project: Project,
    agent: AgentInstance,
};

pub fn detectAgentKind(command: []const u8, start_command: []const u8, title: []const u8) AgentKind {
    const haystacks = [_][]const u8{ command, start_command, title };
    for (haystacks) |haystack| {
        if (containsToken(haystack, "claude")) return .claude;
        if (containsToken(haystack, "codex")) return .codex;
        if (containsToken(haystack, "pi")) return .pi;
        if (containsToken(haystack, "marvin")) return .marvin;
    }
    return .unknown;
}

fn containsToken(haystack: []const u8, token: []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const n = @min(haystack.len, lower_buf.len);
    const lower = lower_buf[0..n];
    for (haystack[0..n], 0..) |char, i| lower[i] = std.ascii.toLower(char);
    return std.mem.indexOf(u8, lower, token) != null;
}

test "detects known agents" {
    try std.testing.expectEqual(AgentKind.claude, detectAgentKind("claude", "", ""));
    try std.testing.expectEqual(AgentKind.codex, detectAgentKind("node", "", "Codex task"));
    try std.testing.expectEqual(AgentKind.marvin, detectAgentKind("sleep", "exec -a marvin sleep 600", ""));
    try std.testing.expectEqual(AgentKind.unknown, detectAgentKind("zsh", "", "editor"));
}
