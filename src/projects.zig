const std = @import("std");
const model = @import("model.zig");

pub fn inferProject(allocator: std.mem.Allocator, cwd: []const u8) !model.Project {
    const root = try findGitRoot(allocator, cwd) orelse try allocator.dupe(u8, cwd);
    errdefer allocator.free(root);
    const name = std.fs.path.basename(root);
    return .{
        .id = root,
        .name = name,
        .root = root,
        .pinned = false,
    };
}

pub fn freeProject(allocator: std.mem.Allocator, project: model.Project) void {
    allocator.free(project.root);
}

fn findGitRoot(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", cwd, "rev-parse", "--show-toplevel" },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return null;
    const output = result.stdout;
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return null;
    const root = try allocator.dupe(u8, trimmed);
    return root;
}

test "infers basename without git" {
    const allocator = std.testing.allocator;
    const project = try inferProject(allocator, "/tmp/example-project");
    defer freeProject(allocator, project);
    try std.testing.expectEqualStrings("example-project", project.name);
}
