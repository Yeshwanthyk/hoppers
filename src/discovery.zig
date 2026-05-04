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
    const kind = detectPaneAgentKind(allocator, pane);
    if (kind == .unknown) return null;

    const project = try projects.inferProject(allocator, pane.current_path);
    errdefer projects.freeProject(allocator, project);

    const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind.label(), pane.pane_id });
    errdefer allocator.free(id);

    const raw_title = activityTitle(pane);
    const title = trimActivityTitle(raw_title, project.name);
    const status = inferStatus(title);
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
        .status = status,
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

fn activityTitle(pane: model.TmuxPane) []const u8 {
    if (pane.title.len > 0) return pane.title;
    if (pane.start_command.len > 0) return pane.start_command;
    return pane.current_command;
}

fn trimActivityTitle(title: []const u8, project_name: []const u8) []const u8 {
    var last_part = title;
    var parts = std.mem.splitSequence(u8, title, "·");
    while (parts.next()) |part| last_part = std.mem.trim(u8, part, " \t");
    if (last_part.len > 0 and !std.mem.eql(u8, last_part, project_name)) return last_part;
    if (std.mem.eql(u8, title, project_name)) return "";
    return title;
}

fn inferStatus(title: []const u8) model.AgentStatus {
    var lower_buf: [256]u8 = undefined;
    const n = @min(title.len, lower_buf.len);
    const lower = lower_buf[0..n];
    for (title[0..n], 0..) |char, i| lower[i] = std.ascii.toLower(char);
    if (contains(lower, "error") or contains(lower, "failed")) return .failed;
    if (contains(lower, "complete") or contains(lower, "done")) return .done;
    if (contains(lower, "ready") or contains(lower, "waiting")) return .waiting;
    if (contains(lower, "executing") or contains(lower, "running")) return .running;
    return .running;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn detectPaneAgentKind(allocator: std.mem.Allocator, pane: model.TmuxPane) model.AgentKind {
    const direct = model.detectAgentKind(pane.current_command, pane.start_command, pane.title);
    if (direct != .unknown) return direct;
    return detectDescendantAgentKind(allocator, pane.pane_pid) catch .unknown;
}

fn detectDescendantAgentKind(allocator: std.mem.Allocator, root_pid: u32) !model.AgentKind {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ps", "-axo", "pid=,ppid=,comm=" },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return .unknown;

    var processes: std.ArrayList(ProcessInfo) = .empty;
    defer processes.deinit(allocator);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const process = parseProcessLine(line) orelse continue;
        try processes.append(allocator, process);
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (processes.items) |*process| {
            if (process.descendant) continue;
            if (process.ppid == root_pid or parentIsDescendant(processes.items, process.ppid)) {
                process.descendant = true;
                changed = true;
            }
        }
    }

    for (processes.items) |process| {
        if (!process.descendant) continue;
        const kind = model.detectAgentKind(process.command, "", "");
        if (kind != .unknown) return kind;
    }
    return .unknown;
}

const ProcessInfo = struct {
    pid: u32,
    ppid: u32,
    command: []const u8,
    descendant: bool = false,
};

fn parseProcessLine(line: []const u8) ?ProcessInfo {
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    const pid_text = parts.next() orelse return null;
    const ppid_text = parts.next() orelse return null;
    const command = parts.next() orelse return null;
    return .{
        .pid = std.fmt.parseInt(u32, pid_text, 10) catch return null,
        .ppid = std.fmt.parseInt(u32, ppid_text, 10) catch return null,
        .command = command,
    };
}

fn parentIsDescendant(processes: []const ProcessInfo, ppid: u32) bool {
    for (processes) |process| {
        if (process.pid == ppid) return process.descendant;
    }
    return false;
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
