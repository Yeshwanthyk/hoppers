const std = @import("std");
const vaxis = @import("vaxis");
const discovery = @import("discovery.zig");
const model = @import("model.zig");
const tmux = @import("tmux.zig");
const sanitize = @import("sanitize.zig");
const tui = @import("tui.zig");

const vxfw = vaxis.vxfw;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse "snapshot";

    if (std.mem.eql(u8, command, "snapshot")) {
        try snapshot(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "jump")) {
        const rank_text = args.next() orelse return error.MissingRank;
        const rank = try std.fmt.parseInt(usize, rank_text, 10);
        try jump(allocator, rank);
        return;
    }

    if (std.mem.eql(u8, command, "jump-relative")) {
        const direction = args.next() orelse return error.MissingDirection;
        try jumpRelative(allocator, direction);
        return;
    }

    if (std.mem.eql(u8, command, "jump-project")) {
        const direction = args.next() orelse return error.MissingDirection;
        try jumpProject(allocator, direction);
        return;
    }

    if (std.mem.eql(u8, command, "sidebar")) {
        try sidebar(allocator);
        return;
    }

    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(allocator);
    try usage(err.writer(allocator));
    try std.fs.File.stderr().writeAll(err.items);
    return error.UnknownCommand;
}

fn snapshot(allocator: std.mem.Allocator) !void {
    const controller = tmux.Controller.init(allocator);
    const panes = try controller.listPanes();
    defer controller.freePanes(panes);

    const items = try discovery.buildCockpit(allocator, panes);
    defer discovery.freeCockpitItems(allocator, items);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try tui.renderSnapshot(out.writer(allocator), items);
    try std.fs.File.stdout().writeAll(out.items);
}

fn sidebar(allocator: std.mem.Allocator) !void {
    const controller = tmux.Controller.init(allocator);
    const panes = try controller.listPanes();
    defer controller.freePanes(panes);

    const items = try discovery.buildCockpit(allocator, panes);
    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    var view: tui.CockpitView = .{ .allocator = allocator, .items = items };
    defer view.deinit();
    try app.run(view.widget(), .{});
}

fn jump(allocator: std.mem.Allocator, rank: usize) !void {
    const controller = tmux.Controller.init(allocator);
    const panes = try controller.listPanes();
    defer controller.freePanes(panes);

    const items = try discovery.buildCockpit(allocator, panes);
    defer discovery.freeCockpitItems(allocator, items);

    for (items) |item| {
        if (item.rank == rank) {
            try controller.switchSession(item.agent.session_name);
            try controller.selectPane(item.agent.pane_id);
            return;
        }
    }
    return error.RankNotFound;
}

fn jumpRelative(allocator: std.mem.Allocator, direction: []const u8) !void {
    const controller = tmux.Controller.init(allocator);
    const panes = try controller.listPanes();
    defer controller.freePanes(panes);

    const active_pane_id = try controller.activePaneId();
    defer allocator.free(active_pane_id);

    const items = try discovery.buildCockpit(allocator, panes);
    defer discovery.freeCockpitItems(allocator, items);
    if (items.len == 0) return error.RankNotFound;

    var active_index: usize = 0;
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.agent.pane_id, active_pane_id)) {
            active_index = index;
            break;
        }
    }

    const target_index = if (std.mem.eql(u8, direction, "next"))
        (active_index + 1) % items.len
    else if (std.mem.eql(u8, direction, "prev"))
        if (active_index == 0) items.len - 1 else active_index - 1
    else
        return error.InvalidDirection;

    const item = items[target_index];
    try controller.switchSession(item.agent.session_name);
    try controller.selectPane(item.agent.pane_id);
}

fn jumpProject(allocator: std.mem.Allocator, direction: []const u8) !void {
    const controller = tmux.Controller.init(allocator);
    const panes = try controller.listPanes();
    defer controller.freePanes(panes);

    const active_pane_id = try controller.activePaneId();
    defer allocator.free(active_pane_id);

    const items = try discovery.buildCockpit(allocator, panes);
    defer discovery.freeCockpitItems(allocator, items);
    if (items.len == 0) return error.RankNotFound;

    var active_project: ?[]const u8 = null;
    for (items) |item| {
        if (std.mem.eql(u8, item.agent.pane_id, active_pane_id)) {
            active_project = item.project.id;
            break;
        }
    }

    const target_index = findProjectTarget(items, active_project, direction) orelse return error.RankNotFound;
    const item = items[target_index];
    try controller.switchSession(item.agent.session_name);
    try controller.selectPane(item.agent.pane_id);
}

fn findProjectTarget(items: []const model.CockpitItem, active_project: ?[]const u8, direction: []const u8) ?usize {
    const current = active_project orelse return firstProjectIndex(items, direction);
    var projects: std.ArrayList(usize) = .empty;
    defer projects.deinit(std.heap.page_allocator);

    var last_project: []const u8 = "";
    for (items, 0..) |item, index| {
        if (index == 0 or !std.mem.eql(u8, item.project.id, last_project)) {
            projects.append(std.heap.page_allocator, index) catch return null;
            last_project = item.project.id;
        }
    }
    if (projects.items.len == 0) return null;

    var active_project_index: usize = 0;
    for (projects.items, 0..) |item_index, project_index| {
        if (std.mem.eql(u8, items[item_index].project.id, current)) {
            active_project_index = project_index;
            break;
        }
    }

    if (std.mem.eql(u8, direction, "next")) return projects.items[(active_project_index + 1) % projects.items.len];
    if (std.mem.eql(u8, direction, "prev")) {
        const previous = if (active_project_index == 0) projects.items.len - 1 else active_project_index - 1;
        return projects.items[previous];
    }
    return null;
}

fn firstProjectIndex(items: []const model.CockpitItem, direction: []const u8) ?usize {
    if (items.len == 0) return null;
    if (std.mem.eql(u8, direction, "next")) return 0;
    if (std.mem.eql(u8, direction, "prev")) {
        var index = items.len - 1;
        const project_id = items[index].project.id;
        while (index > 0 and std.mem.eql(u8, items[index - 1].project.id, project_id)) index -= 1;
        return index;
    }
    return null;
}

fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: hoppers <command>
        \\
        \\commands:
        \\  snapshot      print current project-grouped agent cockpit
        \\  sidebar       run sidebar placeholder (libvaxis TUI lands next)
        \\  jump <rank>              jump to ranked cockpit item
        \\  jump-relative next|prev  jump to next/previous ranked item
        \\
    );
}

test {
    _ = discovery;
    _ = sanitize;
    _ = tmux;
    _ = tui;
}
