const std = @import("std");
const model = @import("model.zig");

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
            "  {d} {s} {s:<7} {s} · {s}\n",
            .{
                item.rank,
                item.agent.status.icon(),
                item.agent.kind.label(),
                item.agent.status.icon(),
                item.agent.title,
            },
        );
    }
}

test "renders empty snapshot" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try renderSnapshot(out.writer(std.testing.allocator), &.{});
    try std.testing.expect(std.mem.indexOf(u8, out.items, "No agent") != null);
}
