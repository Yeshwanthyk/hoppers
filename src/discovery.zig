const std = @import("std");
const model = @import("model.zig");
const projects = @import("projects.zig");
const ranking = @import("ranking.zig");

pub fn buildCockpit(allocator: std.mem.Allocator, panes: []const model.TmuxPane) ![]model.CockpitItem {
    var items: std.ArrayList(model.CockpitItem) = .empty;
    errdefer {
        for (items.items) |item| freeCockpitItem(allocator, item);
        items.deinit(allocator);
    }

    for (panes) |pane| {
        const item = (try buildCockpitItem(allocator, pane)) orelse continue;
        items.append(allocator, item) catch |err| {
            freeCockpitItem(allocator, item);
            return err;
        };
    }

    const owned = try items.toOwnedSlice(allocator);
    ranking.assignRanks(owned);
    return owned;
}

pub fn freeCockpitItems(allocator: std.mem.Allocator, items: []model.CockpitItem) void {
    for (items) |item| freeCockpitItem(allocator, item);
    allocator.free(items);
}

fn buildCockpitItem(allocator: std.mem.Allocator, pane: model.TmuxPane) !?model.CockpitItem {
    const kind = model.detectAgentKind(pane.current_command, pane.start_command, pane.title);
    if (kind == .unknown) return null;

    const project = try projects.inferProject(allocator, pane.current_path);
    errdefer projects.freeProject(allocator, project);

    const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind.label(), pane.pane_id });
    errdefer allocator.free(id);

    const title = if (pane.title.len > 0) pane.title else pane.current_command;
    const owned_session_name = try allocator.dupe(u8, pane.session_name);
    errdefer allocator.free(owned_session_name);
    const owned_window_id = try allocator.dupe(u8, pane.window_id);
    errdefer allocator.free(owned_window_id);
    const owned_pane_id = try allocator.dupe(u8, pane.pane_id);
    errdefer allocator.free(owned_pane_id);
    const owned_title = try allocator.dupe(u8, title);
    errdefer allocator.free(owned_title);

    const agent: model.AgentInstance = .{
        .id = id,
        .kind = kind,
        .status = .running,
        .project_id = project.id,
        .session_name = owned_session_name,
        .window_id = owned_window_id,
        .pane_id = owned_pane_id,
        .title = owned_title,
        .last_seen_ms = std.time.milliTimestamp(),
    };
    const priority = ranking.agentPriority(project, agent);
    return .{ .rank = 0, .priority = priority, .project = project, .agent = agent };
}

fn freeCockpitItem(allocator: std.mem.Allocator, item: model.CockpitItem) void {
    projects.freeProject(allocator, item.project);
    allocator.free(item.agent.id);
    allocator.free(item.agent.session_name);
    allocator.free(item.agent.window_id);
    allocator.free(item.agent.pane_id);
    allocator.free(item.agent.title);
}

test "builds cockpit from agent panes" {
    const panes = [_]model.TmuxPane{.{
        .session_name = "hoppers",
        .window_id = "@1",
        .pane_id = "%1",
        .pane_pid = 1,
        .current_command = "sleep",
        .start_command = "exec -a claude sleep 600",
        .current_path = "/tmp/hoppers",
        .title = "Claude task",
    }};
    const items = try buildCockpit(std.testing.allocator, &panes);
    defer freeCockpitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(model.AgentKind.claude, items[0].agent.kind);
}
