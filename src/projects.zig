const std = @import("std");
const model = @import("model.zig");

pub fn inferProject(allocator: std.mem.Allocator, cwd: []const u8) !model.Project {
    const root = try findGitRoot(allocator, cwd) orelse try allocator.dupe(u8, cwd);
    errdefer allocator.free(root);
    const id = try gitProjectRoot(allocator, root);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, std.fs.path.basename(id));
    errdefer allocator.free(name);
    const branch = try gitBranch(allocator, root) orelse try allocator.dupe(u8, "");
    errdefer allocator.free(branch);
    const ports = try allocator.alloc(u16, 0);
    errdefer allocator.free(ports);
    return .{
        .id = id,
        .name = name,
        .root = root,
        .branch = branch,
        .dirty = try gitDirty(allocator, root),
        .worktree = try gitWorktree(allocator, root),
        .ports = ports,
        .pinned = false,
    };
}

pub fn freeProject(allocator: std.mem.Allocator, project: model.Project) void {
    allocator.free(project.id);
    allocator.free(project.name);
    allocator.free(project.root);
    allocator.free(project.branch);
    allocator.free(project.ports);
}

fn gitProjectRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir" },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return allocator.dupe(u8, root);
    const common_dir = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (std.mem.endsWith(u8, common_dir, "/.git")) {
        return allocator.dupe(u8, std.fs.path.dirname(common_dir) orelse root);
    }
    const worktrees_dir = std.fs.path.dirname(common_dir) orelse return allocator.dupe(u8, root);
    const git_dir = std.fs.path.dirname(worktrees_dir) orelse return allocator.dupe(u8, root);
    if (!std.mem.endsWith(u8, git_dir, "/.git")) return allocator.dupe(u8, root);
    return allocator.dupe(u8, std.fs.path.dirname(git_dir) orelse root);
}

fn gitBranch(allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", root, "branch", "--show-current" },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (trimmed.len == 0) return null;
    const branch = try allocator.dupe(u8, trimmed);
    return branch;
}

fn gitDirty(allocator: std.mem.Allocator, root: []const u8) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", root, "status", "--porcelain" },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return false;
    return std.mem.trim(u8, result.stdout, " \n\r\t").len > 0;
}

fn gitWorktree(allocator: std.mem.Allocator, root: []const u8) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", root, "rev-parse", "--git-common-dir" },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return false;
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    return !std.mem.eql(u8, trimmed, ".git");
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
