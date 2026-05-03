const std = @import("std");
const vaxis = @import("vaxis");
const discovery = @import("discovery.zig");
const model = @import("model.zig");
const tmux = @import("tmux.zig");

const vxfw = vaxis.vxfw;

pub fn renderSnapshot(writer: anytype, items: []const model.CockpitItem) !void {
    try writer.writeAll("hoppers · project cockpit\n\n");
    if (items.len == 0) {
        try writer.writeAll("No agent panes detected.\n");
        return;
    }

    var current_project: []const u8 = "";
    for (items) |item| {
        if (!std.mem.eql(u8, current_project, item.project.name)) {
            current_project = item.project.name;
            try writer.print("{s}\n", .{current_project});
        }
        try writer.print(
            "  {d} {s:<7} {s:<7} - {s}\n",
            .{ item.rank, item.agent.kind.label(), item.agent.status.label(), item.agent.title },
        );
    }
}

pub const CockpitView = struct {
    allocator: std.mem.Allocator,
    items: []model.CockpitItem,
    refresh_ms: u32 = 3000,

    pub fn deinit(self: *CockpitView) void {
        discovery.freeCockpitItems(self.allocator, self.items);
        self.* = undefined;
    }

    pub fn widget(self: *CockpitView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = CockpitView.typeErasedEventHandler,
            .drawFn = CockpitView.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *CockpitView = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => try ctx.tick(self.refresh_ms, self.widget()),
            .tick => {
                try self.refresh();
                ctx.redraw = true;
                try ctx.tick(self.refresh_ms, self.widget());
            },
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }

    fn refresh(self: *CockpitView) !void {
        const controller = tmux.Controller.init(self.allocator);
        const panes = try controller.listPanes();
        defer controller.freePanes(panes);

        const next_items = try discovery.buildCockpit(self.allocator, panes);
        discovery.freeCockpitItems(self.allocator, self.items);
        self.items = next_items;
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CockpitView = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), max_size);

        var row: u16 = 0;
        writeText(surface, 0, row, "hoppers · project cockpit", .{ .bold = true });
        row += 1;
        var count_buf: [32]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "agents: {d}", .{self.items.len}) catch "agents: ?";
        writeText(surface, 0, row, count_text, .{ .dim = true });
        row += 1;

        if (self.items.len == 0) {
            writeText(surface, 0, row, "No agent panes detected.", .{ .dim = true });
            return surface;
        }

        var current_project: []const u8 = "";
        for (self.items) |item| {
            if (row >= max_size.height) break;
            if (!std.mem.eql(u8, current_project, item.project.name)) {
                current_project = item.project.name;
                writeText(surface, 0, row, current_project, .{ .bold = true });
                row += 1;
            }
            if (row >= max_size.height) break;
            writeItem(surface, row, item);
            row += 1;
        }

        if (max_size.height > 1) {
            writeText(
                surface,
                0,
                max_size.height - 1,
                "q quit · rescans every 3s · use tmux h → 1..3 to jump",
                .{ .dim = true },
            );
        }
        return surface;
    }
};

fn writeItem(surface: vxfw.Surface, row: u16, item: model.CockpitItem) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "  {d} {s:<7} {s:<7} - {s}",
        .{ item.rank, item.agent.kind.label(), item.agent.status.label(), item.agent.title },
    ) catch "  <render error>";
    writeText(surface, 0, row, text, .{});
}

fn writeText(surface: vxfw.Surface, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    var x = col;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (iter.nextCodepointSlice()) |grapheme| {
        if (x >= surface.size.width) break;
        surface.writeCell(x, row, .{ .char = .{ .grapheme = grapheme }, .style = style });
        x += 1;
    }
}

test "renders empty snapshot" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try renderSnapshot(out.writer(std.testing.allocator), &.{});
    try std.testing.expect(std.mem.indexOf(u8, out.items, "No agent") != null);
}
