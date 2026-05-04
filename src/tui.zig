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

const FilterMode = enum {
    all,
    hot,
    active,

    fn next(self: FilterMode) FilterMode {
        return switch (self) {
            .all => .hot,
            .hot => .active,
            .active => .all,
        };
    }

    fn label(self: FilterMode) []const u8 {
        return switch (self) {
            .all => "all",
            .hot => "hot",
            .active => "active",
        };
    }
};

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
    filter: FilterMode = .all,

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
                if (key.matches('f', .{})) {
                    self.filter = self.filter.next();
                    self.ensureVisibleSelection();
                    ctx.redraw = true;
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
        const current_index = self.selectedIndex() orelse self.firstVisibleIndex() orelse return;
        var next_index = current_index;
        while (true) {
            next_index = switch (direction) {
                .next => (next_index + 1) % self.items.len,
                .prev => if (next_index == 0) self.items.len - 1 else next_index - 1,
            };
            if (self.isVisible(self.items[next_index])) {
                self.selected_rank = self.items[next_index].rank;
                return;
            }
            if (next_index == current_index) return;
        }
    }

    fn selectPaneRank(self: *CockpitView, pane_id: []const u8) void {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.agent.pane_id, pane_id)) {
                self.selected_rank = item.rank;
                return;
            }
        }
    }

    fn selectRank(self: *CockpitView, rank: usize) void {
        for (self.items) |item| {
            if (item.rank == rank and self.isVisible(item)) {
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
            if (item.rank == self.selected_rank and self.isVisible(item)) return index;
        }
        return null;
    }

    fn firstVisibleIndex(self: *CockpitView) ?usize {
        for (self.items, 0..) |item, index| {
            if (self.isVisible(item)) return index;
        }
        return null;
    }

    fn ensureVisibleSelection(self: *CockpitView) void {
        if (self.selectedIndex() != null) return;
        if (self.firstVisibleIndex()) |index| self.selected_rank = self.items[index].rank;
    }

    fn isVisible(self: *CockpitView, item: model.CockpitItem) bool {
        return switch (self.filter) {
            .all => true,
            .hot => isHot(item.agent.status),
            .active => isActive(item.agent.status),
        };
    }

    fn refresh(self: *CockpitView) !void {
        const controller = tmux.Controller.init(self.allocator);
        const panes = try controller.listPanes();
        defer controller.freePanes(panes);

        const active_pane_id = controller.activePaneId() catch |err| switch (err) {
            error.CommandFailed => null,
            else => return err,
        };
        defer if (active_pane_id) |pane_id| self.allocator.free(pane_id);

        const next_items = try discovery.buildCockpit(self.allocator, panes);
        discovery.freeCockpitItems(self.allocator, self.items);
        self.items = next_items;
        if (active_pane_id) |pane_id| self.selectPaneRank(pane_id);
        self.ensureVisibleSelection();
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CockpitView = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), max_size);

        if (max_size.height == 0 or max_size.width == 0) return surface;
        clearSurface(surface);

        const footer_visible = max_size.height >= 8;
        const content_bottom = if (footer_visible) max_size.height - 2 else max_size.height;
        var row: u16 = drawHeader(surface, self.items, self.filter);

        if (self.items.len == 0) {
            if (row < content_bottom) writeText(surface, 1, row, "no agent panes detected", subtleStyle());
            drawFooter(surface, max_size, footer_visible);
            return surface;
        }

        var current_project: []const u8 = "";
        var current_subgroup: []const u8 = "";
        var visible_items: usize = 0;
        for (self.items, 0..) |item, index| {
            if (!self.isVisible(item)) continue;
            visible_items += 1;
            if (!std.mem.eql(u8, current_project, item.project.id)) {
                if (row + 3 >= content_bottom) break;
                current_project = item.project.id;
                current_subgroup = "";
                const stats = projectStats(self.items[index..], current_project, self.filter);
                row = writeProject(surface, row, item.project, stats);
            }
            if (!std.mem.eql(u8, current_subgroup, item.project.root)) {
                if (row + 1 >= content_bottom) break;
                current_subgroup = item.project.root;
                writeSubgroup(surface, row, item.project, self.items[index..]);
                row += 1;
            }
            if (row >= content_bottom) break;
            const selected = item.rank == self.selected_rank;
            writeItem(surface, row, item, selected);
            row += 1;
        }

        if (visible_items == 0) {
            if (row < content_bottom) writeText(surface, 1, row, "no agents match filter", subtleStyle());
            drawFooter(surface, max_size, footer_visible);
            return surface;
        }

        drawFooter(surface, max_size, footer_visible);
        return surface;
    }
};

fn drawHeader(surface: vxfw.Surface, items: []const model.CockpitItem, filter: FilterMode) u16 {
    const stats = listStats(items);
    writeText(surface, 1, 0, "hoppers", .{ .fg = theme.text, .bold = true });
    var buf: [64]u8 = undefined;
    var heat_buf: [48]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "{s} · {d} · {s}", .{
        filter.label(),
        stats.total,
        heatLabel(&heat_buf, stats),
    }) catch "";
    writeRight(surface, 0, summary, 1, .{ .fg = theme.accent, .bold = true });
    drawRule(surface, 1, theme.surface2);
    return 2;
}

fn writeProject(surface: vxfw.Surface, row: u16, project: model.Project, stats: StatusCounts) u16 {
    var next = row;
    if (next > 2) {
        drawRule(surface, next, theme.surface);
        next += 1;
    }
    writeText(surface, 1, next, project.name, .{ .fg = theme.text, .bold = true });
    var buf: [48]u8 = undefined;
    const heat = heatLabel(&buf, stats);
    if (heat.len > 0) writeRight(surface, next, heat, 1, subtleStyle());

    return next + 1;
}

fn writeSubgroup(surface: vxfw.Surface, row: u16, project: model.Project, items: []const model.CockpitItem) void {
    var col: u16 = 3;
    const style = subtleStyle();
    const label = if (project.branch.len > 0) project.branch else std.fs.path.basename(project.root);
    col = writeTextBounded(surface, col, row, label, style);
    if (project.branch.len > 0 and project.dirty) col = writeTextBounded(surface, col, row, "*", style);
    if (project.branch.len > 0 and project.worktree) col = writeTextBounded(surface, col, row, " wt", style);
    var rendered: [32]u16 = undefined;
    var rendered_len: usize = 0;
    for (items) |item| {
        if (!std.mem.eql(u8, item.project.id, project.id)) break;
        if (!std.mem.eql(u8, item.project.root, project.root)) continue;
        for (item.project.ports) |port| {
            if (containsPort(rendered[0..rendered_len], port)) continue;
            if (rendered_len < rendered.len) {
                rendered[rendered_len] = port;
                rendered_len += 1;
            }
            col = writeTextBounded(surface, col, row, " :", style);
            col = writePort(surface, col, row, port, style);
        }
    }
}

fn containsPort(ports: []const u16, port: u16) bool {
    for (ports) |existing| {
        if (existing == port) return true;
    }
    return false;
}

fn writeTextBounded(surface: vxfw.Surface, col: u16, row: u16, text: []const u8, style: vaxis.Style) u16 {
    var x = col;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (iter.nextCodepointSlice()) |grapheme| {
        if (x + 1 >= surface.size.width) return x;
        surface.writeCell(x, row, .{ .char = .{ .grapheme = grapheme }, .style = style });
        x += 1;
    }
    return x;
}

fn writePort(surface: vxfw.Surface, col: u16, row: u16, port: u16, style: vaxis.Style) u16 {
    var digits: [5]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{port}) catch return col;
    var x = col;
    for (text) |digit| {
        if (x + 1 >= surface.size.width) return x;
        surface.writeCell(x, row, .{ .char = .{ .grapheme = digitGrapheme(digit) }, .style = style });
        x += 1;
    }
    return x;
}

fn digitGrapheme(digit: u8) []const u8 {
    return switch (digit) {
        '0' => "0",
        '1' => "1",
        '2' => "2",
        '3' => "3",
        '4' => "4",
        '5' => "5",
        '6' => "6",
        '7' => "7",
        '8' => "8",
        '9' => "9",
        else => "?",
    };
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
    writeText(surface, 10, row, statusIcon(item.agent.status), status_style);
    writeText(surface, 13, row, statusReasonShort(item.agent.status), status_style);

    const title_col: u16 = 18;
    if (surface.size.width > title_col and item.agent.title.len > 0) {
        const title_width = surface.size.width - title_col;
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
    writeText(surface, 1, row, "j/k select · enter jump · f filter · r refresh · q", subtleStyle());
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

const StatusCounts = struct {
    total: usize = 0,
    waiting: usize = 0,
    failed: usize = 0,
    running: usize = 0,
    done: usize = 0,
};

fn listStats(items: []const model.CockpitItem) StatusCounts {
    var stats: StatusCounts = .{};
    for (items) |item| addStatus(&stats, item.agent.status);
    return stats;
}

fn projectStats(items: []const model.CockpitItem, project_id: []const u8, filter: FilterMode) StatusCounts {
    var stats: StatusCounts = .{};
    for (items) |item| {
        if (!std.mem.eql(u8, item.project.id, project_id)) break;
        if (!statusVisible(filter, item.agent.status)) continue;
        addStatus(&stats, item.agent.status);
    }
    return stats;
}

fn addStatus(stats: *StatusCounts, status: model.AgentStatus) void {
    stats.total += 1;
    switch (status) {
        .waiting => stats.waiting += 1,
        .failed => stats.failed += 1,
        .running => stats.running += 1,
        .done => stats.done += 1,
        .stale, .idle => {},
    }
}

fn heatLabel(buf: []u8, stats: StatusCounts) []const u8 {
    if (stats.total == 0) return "";
    if (stats.waiting > 0 and stats.failed > 0 and stats.running > 0)
        return std.fmt.bufPrint(buf, "!{d} x{d} >{d}", .{ stats.waiting, stats.failed, stats.running }) catch "";
    if (stats.waiting > 0 and stats.failed > 0)
        return std.fmt.bufPrint(buf, "!{d} x{d}", .{ stats.waiting, stats.failed }) catch "";
    if (stats.waiting > 0 and stats.running > 0)
        return std.fmt.bufPrint(buf, "!{d} >{d}", .{ stats.waiting, stats.running }) catch "";
    if (stats.failed > 0 and stats.running > 0)
        return std.fmt.bufPrint(buf, "x{d} >{d}", .{ stats.failed, stats.running }) catch "";
    if (stats.waiting > 0) return std.fmt.bufPrint(buf, "!{d}", .{stats.waiting}) catch "";
    if (stats.failed > 0) return std.fmt.bufPrint(buf, "x{d}", .{stats.failed}) catch "";
    if (stats.running > 0) return std.fmt.bufPrint(buf, ">{d}", .{stats.running}) catch "";
    if (stats.done > 0) return std.fmt.bufPrint(buf, "v{d}", .{stats.done}) catch "";
    return "idle";
}

fn statusVisible(filter: FilterMode, status: model.AgentStatus) bool {
    return switch (filter) {
        .all => true,
        .hot => isHot(status),
        .active => isActive(status),
    };
}

fn isHot(status: model.AgentStatus) bool {
    return switch (status) {
        .waiting, .failed, .done, .stale => true,
        .running, .idle => false,
    };
}

fn isActive(status: model.AgentStatus) bool {
    return switch (status) {
        .waiting, .running => true,
        .failed, .done, .stale, .idle => false,
    };
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
        .waiting => "!",
        .done => "v",
        .failed => "x",
        .stale => "~",
        .idle => "·",
    };
}

fn statusReasonShort(status: model.AgentStatus) []const u8 {
    return switch (status) {
        .idle => "idle",
        .running => "run",
        .waiting => "input",
        .done => "done",
        .failed => "fail",
        .stale => "stale",
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
