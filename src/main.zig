const std = @import("std");
const vaxis = @import("vaxis");
const discovery = @import("discovery.zig");
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

fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: hoppers <command>
        \\
        \\commands:
        \\  snapshot      print current project-grouped agent cockpit
        \\  sidebar       run sidebar placeholder (libvaxis TUI lands next)
        \\  jump <rank>   jump to ranked cockpit item
        \\
    );
}

test {
    _ = discovery;
    _ = sanitize;
    _ = tmux;
    _ = tui;
}
