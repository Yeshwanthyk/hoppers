const std = @import("std");
const model = @import("model.zig");

pub fn statusPriority(status: model.AgentStatus) i32 {
    return switch (status) {
        .waiting => 500,
        .failed => 400,
        .done => 300,
        .running => 200,
        .stale => 50,
        .idle => 0,
    };
}

pub fn agentPriority(project: model.Project, agent: model.AgentInstance) i32 {
    var score = statusPriority(agent.status);
    if (agent.unseen) score += 40;
    if (project.pinned) score += 25;
    return score;
}

pub fn lessThan(_: void, left: model.CockpitItem, right: model.CockpitItem) bool {
    if (left.priority != right.priority) return left.priority > right.priority;
    if (left.agent.last_seen_ms != right.agent.last_seen_ms) return left.agent.last_seen_ms > right.agent.last_seen_ms;
    const project_order = std.mem.order(u8, left.project.name, right.project.name);
    if (project_order != .eq) return project_order == .lt;
    return std.mem.order(u8, left.agent.kind.label(), right.agent.kind.label()) == .lt;
}

pub fn assignRanks(items: []model.CockpitItem) void {
    std.mem.sort(model.CockpitItem, items, {}, lessThan);
    for (items, 0..) |*item, idx| item.rank = idx + 1;
}

test "ranking prefers waiting over running" {
    const project: model.Project = .{ .id = "p", .name = "p", .root = "/tmp/p" };
    var items = [_]model.CockpitItem{
        .{
            .rank = 0,
            .priority = 0,
            .project = project,
            .agent = .{
                .id = "a",
                .kind = .claude,
                .status = .running,
                .project_id = "p",
                .session_name = "p",
                .window_id = "@1",
                .pane_id = "%1",
                .title = "running",
            },
        },
        .{
            .rank = 0,
            .priority = 0,
            .project = project,
            .agent = .{
                .id = "b",
                .kind = .codex,
                .status = .waiting,
                .project_id = "p",
                .session_name = "p",
                .window_id = "@2",
                .pane_id = "%2",
                .title = "waiting",
            },
        },
    };
    for (&items) |*item| item.priority = agentPriority(item.project, item.agent);
    assignRanks(&items);
    try std.testing.expectEqual(model.AgentKind.codex, items[0].agent.kind);
}
