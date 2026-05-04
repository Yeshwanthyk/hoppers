const std = @import("std");
const vaxis = @import("vaxis");
const discovery = @import("discovery.zig");
const model = @import("model.zig");
const tmux = @import("tmux.zig");

const vxfw = vaxis.vxfw;

const Theme = struct {
    base: vaxis.Color = vaxis.Color.rgbFromUint(0x11111b),
    surface: vaxis.Color = vaxis.Color.rgbFromUint(0x313244),
    surface2: vaxis.Color = vaxis.Color.rgbFromUint(0x45475a),
    text: vaxis.Color = vaxis.Color.rgbFromUint(0xcdd6f4),
    muted: vaxis.Color = vaxis.Color.rgbFromUint(0x6c7086),
    subtext: vaxis.Color = vaxis.Color.rgbFromUint(0xa6adc8),
    accent: vaxis.Color = vaxis.Color.rgbFromUint(0xcba6f7),
    running: vaxis.Color = vaxis.Color.rgbFromUint(0xf9e2af),
    waiting: vaxis.Color = vaxis.Color.rgbFromUint(0x89b4fa),
    done: vaxis.Color = vaxis.Color.rgbFromUint(0xa6e3a1),
    failed: vaxis.Color = vaxis.Color.rgbFromUint(0xf38ba8),
};

const theme: Theme = .{};

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
            "  {d} {s:<7} {s:<7} {s}\n",
            .{ item.rank, item.agent.kind.label(), item.project.name, item.project.root },
        );
    }
}

pub const CockpitView = struct {
    allocator: std.mem.Allocator,
    items: []model.CockpitItem,
    refresh_ms: u32 = 3000,
    selected_rank: usize = 1,

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
                if (key.matches('j', .{})) {
                    self.moveSelection(.next);
                    ctx.redraw = true;
                    return;
                }
                if (key.matches('k', .{})) {
                    self.moveSelection(.prev);
                    ctx.redraw = true;
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    try self.jumpSelected();
                    return;
                }
                if (key.codepoint >= '1' and key.codepoint <= '9') {
                    self.selectRank(@intCast(key.codepoint - '0'));
                    ctx.redraw = true;
                    return;
                }
                if (key.matches('r', .{})) {
                    try self.refresh();
                    ctx.redraw = true;
                    return;
                }
            },
            else => {},
        }
    }

    const Direction = enum { next, prev };

    fn moveSelection(self: *CockpitView, direction: Direction) void {
        if (self.items.len == 0) return;
        const current_index = self.selectedIndex() orelse 0;
        const next_index = switch (direction) {
            .next => (current_index + 1) % self.items.len,
            .prev => if (current_index == 0) self.items.len - 1 else current_index - 1,
        };
        self.selected_rank = self.items[next_index].rank;
    }

    fn selectRank(self: *CockpitView, rank: usize) void {
        for (self.items) |item| {
            if (item.rank == rank) {
                self.selected_rank = rank;
                return;
            }
        }
    }

    fn jumpSelected(self: *CockpitView) !void {
        const index = self.selectedIndex() orelse return;
        const item = self.items[index];
        const controller = tmux.Controller.init(self.allocator);
        try controller.switchSession(item.agent.session_name);
        try controller.selectPane(item.agent.pane_id);
    }

    fn selectedIndex(self: *CockpitView) ?usize {
        for (self.items, 0..) |item, index| {
            if (item.rank == self.selected_rank) return index;
        }
        return null;
    }

    fn refresh(self: *CockpitView) !void {
        const controller = tmux.Controller.init(self.allocator);
        const panes = try controller.listPanes();
        defer controller.freePanes(panes);

        const next_items = try discovery.buildCockpit(self.allocator, panes);
        discovery.freeCockpitItems(self.allocator, self.items);
        self.items = next_items;
        if (self.selectedIndex() == null and self.items.len > 0) self.selected_rank = self.items[0].rank;
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CockpitView = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), max_size);

        if (max_size.height == 0 or max_size.width == 0) return surface;
        clearSurface(surface);

        const footer_visible = max_size.height >= 8;
        const content_bottom = if (footer_visible) max_size.height - 2 else max_size.height;
        var row: u16 = 0;

        if (self.items.len == 0) {
            if (row < content_bottom) writeText(surface, 1, row, "no agent panes detected", subtleStyle());
            drawFooter(surface, max_size, footer_visible);
            return surface;
        }

        var current_project: []const u8 = "";
        var project_agents: usize = 0;
        for (self.items, 0..) |item, index| {
            if (!std.mem.eql(u8, current_project, item.project.name)) {
                if (row + 2 >= content_bottom) break;
                current_project = item.project.name;
                project_agents = countProjectAgents(self.items[index..], current_project);
                row = writeProject(surface, row, current_project, project_agents);
            }
            if (row >= content_bottom) break;
            const selected = item.rank == self.selected_rank;
            writeItem(surface, row, item, selected);
            row += 1;
            if (selected and row < content_bottom and item.agent.title.len > 0 and max_size.width > 32) {
                writeText(surface, 3, row, "↳", subtleStyle());
                writeTextTruncated(surface, 5, row, item.agent.title, max_size.width - 6, subtleStyle());
                row += 1;
            }
        }

        drawFooter(surface, max_size, footer_visible);
        return surface;
    }
};

fn writeProject(surface: vxfw.Surface, row: u16, name: []const u8, _: usize) u16 {
    var next = row;
    if (next > 2) {
        drawRule(surface, next, theme.surface);
        next += 1;
    }
    writeText(surface, 1, next, name, .{ .fg = theme.text, .bold = true });

    return next + 1;
}

fn writeItem(surface: vxfw.Surface, row: u16, item: model.CockpitItem, selected: bool) void {
    const status_style = statusStyle(item.agent.status);
    const kind_style: vaxis.Style = .{ .fg = kindColor(item.agent.kind), .bold = true };
    const text_style: vaxis.Style = .{ .fg = theme.text };
    const rank_style: vaxis.Style = if (selected)
        .{ .fg = theme.base, .bg = theme.accent, .bold = true }
    else
        .{ .fg = theme.accent, .bold = true };

    writeText(surface, 1, row, rankLabel(item.rank), rank_style);
    writeText(surface, 3, row, item.agent.kind.label(), kind_style);
    writeText(surface, 7, row, statusIcon(item.agent.status), status_style);

    const title_col: u16 = 10;
    if (surface.size.width > 42) {
        writeRight(surface, row, item.agent.status.label(), 1, status_style);
        const status_width = displayWidth(item.agent.status.label()) + 2;
        if (item.agent.title.len > 0 and surface.size.width > title_col + status_width) {
            const title_width = surface.size.width - title_col - status_width;
            writeTextTruncated(surface, title_col, row, item.agent.title, title_width, text_style);
        }
    } else if (surface.size.width > title_col and item.agent.title.len > 0) {
        const title_width = surface.size.width - title_col - 1;
        writeTextTruncated(surface, title_col, row, item.agent.title, title_width, text_style);
    }
}

fn clearSurface(surface: vxfw.Surface) void {
    var row: u16 = 0;
    while (row < surface.size.height) : (row += 1) {
        var col: u16 = 0;
        while (col < surface.size.width) : (col += 1) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = .{} });
        }
    }
}

fn drawFooter(surface: vxfw.Surface, size: vxfw.Size, visible: bool) void {
    if (!visible) return;
    const row = size.height - 1;
    drawRule(surface, row - 1, theme.surface2);
    writeText(surface, 1, row, "j/k select · enter jump · q", subtleStyle());
}

fn drawRule(surface: vxfw.Surface, row: u16, color: vaxis.Color) void {
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        surface.writeCell(col, row, .{ .char = .{ .grapheme = "─" }, .style = .{ .fg = color } });
    }
}

fn writeRight(surface: vxfw.Surface, row: u16, text: []const u8, margin: u16, style: vaxis.Style) void {
    const width = displayWidth(text);
    if (width + margin >= surface.size.width) return;
    const col: u16 = @intCast(surface.size.width - margin - width);
    writeText(surface, col, row, text, style);
}

fn writeTextTruncated(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    text: []const u8,
    max_width: u16,
    style: vaxis.Style,
) void {
    if (max_width == 0) return;
    var x = col;
    var written: u16 = 0;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (iter.nextCodepointSlice()) |grapheme| {
        if (x >= surface.size.width or written >= max_width) break;
        if (written + 1 == max_width and iter.i < text.len) {
            surface.writeCell(x, row, .{ .char = .{ .grapheme = "…" }, .style = style });
            return;
        }
        surface.writeCell(x, row, .{ .char = .{ .grapheme = grapheme }, .style = style });
        x += 1;
        written += 1;
    }
}

fn writeText(surface: vxfw.Surface, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= surface.size.height) return;
    var x = col;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (iter.nextCodepointSlice()) |grapheme| {
        if (x >= surface.size.width) break;
        surface.writeCell(x, row, .{ .char = .{ .grapheme = grapheme }, .style = style });
        x += 1;
    }
}

fn countProjectAgents(items: []const model.CockpitItem, project_name: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (!std.mem.eql(u8, item.project.name, project_name)) break;
        count += 1;
    }
    return count;
}

fn displayWidth(text: []const u8) u16 {
    var width: u16 = 0;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (iter.nextCodepointSlice()) |_| width += 1;
    return width;
}

fn rankLabel(rank: usize) []const u8 {
    return switch (rank) {
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        else => "+",
    };
}

fn statusIcon(status: model.AgentStatus) []const u8 {
    return switch (status) {
        .running => "|>",
        .waiting => "?",
        .done => "✓",
        .failed => "!",
        .stale => "~",
        .idle => "·",
    };
}

fn statusStyle(status: model.AgentStatus) vaxis.Style {
    return .{ .fg = switch (status) {
        .running => theme.running,
        .waiting => theme.waiting,
        .done => theme.done,
        .failed => theme.failed,
        .stale => theme.running,
        .idle => theme.muted,
    } };
}

fn subtleStyle() vaxis.Style {
    return .{ .fg = theme.muted };
}

fn kindColor(kind: model.AgentKind) vaxis.Color {
    return switch (kind) {
        .claude => vaxis.Color.rgbFromUint(0xfab387),
        .codex => vaxis.Color.rgbFromUint(0x89dceb),
        .pi => vaxis.Color.rgbFromUint(0xcba6f7),
        .marvin => vaxis.Color.rgbFromUint(0xa6e3a1),
        .unknown => theme.subtext,
    };
}

test "renders empty snapshot" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try renderSnapshot(out.writer(std.testing.allocator), &.{});
    try std.testing.expect(std.mem.indexOf(u8, out.items, "No agent") != null);
}
