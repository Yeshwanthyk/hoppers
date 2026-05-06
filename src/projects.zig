const std = @import("std");
const model = @import("model.zig");

pub const ProjectCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(model.Project),

    pub fn init(allocator: std.mem.Allocator) ProjectCache {
        return .{ .allocator = allocator, .entries = std.StringHashMap(model.Project).init(allocator) };
    }

    pub fn deinit(self: *ProjectCache) void {
        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeProject(self.allocator, entry.value_ptr.*);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn infer(self: *ProjectCache, cwd: []const u8) !model.Project {
        if (self.entries.get(cwd)) |project| return cloneProject(self.allocator, project);

        const key = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(key);
        const project = try inferProject(self.allocator, cwd);
        errdefer freeProject(self.allocator, project);
        try self.entries.put(key, project);
        return cloneProject(self.allocator, project);
    }
};

pub fn inferProject(allocator: std.mem.Allocator, cwd: []const u8) !model.Project {
    const root = try findGitRoot(allocator, cwd) orelse try allocator.dupe(u8, cwd);
    errdefer allocator.free(root);

    const metadata = try gitMetadata(allocator, root);
    defer metadata.deinit(allocator);

    const id = try projectIdFromGitCommonDir(allocator, root, metadata.common_dir);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, std.fs.path.basename(id));
    errdefer allocator.free(name);
    const branch = try allocator.dupe(u8, metadata.branch);
    errdefer allocator.free(branch);
    const ports = try allocator.alloc(u16, 0);
    errdefer allocator.free(ports);
    return .{
        .id = id,
        .name = name,
        .root = root,
        .branch = branch,
        .dirty = metadata.dirty,
        .worktree = metadata.worktree,
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

fn cloneProject(allocator: std.mem.Allocator, project: model.Project) !model.Project {
    const id = try allocator.dupe(u8, project.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, project.name);
    errdefer allocator.free(name);
    const root = try allocator.dupe(u8, project.root);
    errdefer allocator.free(root);
    const branch = try allocator.dupe(u8, project.branch);
    errdefer allocator.free(branch);
    const ports = try allocator.dupe(u16, project.ports);
    errdefer allocator.free(ports);
    return .{
        .id = id,
        .name = name,
        .root = root,
        .branch = branch,
        .dirty = project.dirty,
        .worktree = project.worktree,
        .ports = ports,
        .pinned = project.pinned,
    };
}

const GitMetadata = struct {
    common_dir: []const u8 = "",
    branch: []const u8 = "",
    dirty: bool = false,
    worktree: bool = false,

    fn deinit(self: GitMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.common_dir);
        allocator.free(self.branch);
    }
};

fn gitMetadata(allocator: std.mem.Allocator, root: []const u8) !GitMetadata {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", root, "status", "--porcelain=v1", "--branch" },
        .max_output_bytes = 256 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return emptyGitMetadata(allocator);

    var metadata = try parseGitStatus(allocator, result.stdout);
    errdefer metadata.deinit(allocator);
    const common_dir = try gitCommonDir(allocator, root);
    allocator.free(metadata.common_dir);
    metadata.common_dir = common_dir;
    const primary_git_dir = try std.fs.path.join(allocator, &.{ root, ".git" });
    defer allocator.free(primary_git_dir);
    metadata.worktree = common_dir.len > 0 and !std.mem.eql(u8, common_dir, primary_git_dir);
    return metadata;
}

fn emptyGitMetadata(allocator: std.mem.Allocator) !GitMetadata {
    return .{ .common_dir = try allocator.dupe(u8, ""), .branch = try allocator.dupe(u8, "") };
}

fn parseGitStatus(allocator: std.mem.Allocator, status: []const u8) !GitMetadata {
    var branch: []const u8 = "";
    var dirty = false;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            branch = parseStatusBranch(line[3..]);
        } else {
            dirty = true;
        }
    }
    return .{
        .common_dir = try allocator.dupe(u8, ""),
        .branch = try allocator.dupe(u8, branch),
        .dirty = dirty,
    };
}

fn parseStatusBranch(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "HEAD ")) return "";
    if (std.mem.startsWith(u8, name, "No commits yet on ")) return name[18..];
    const upstream = std.mem.indexOf(u8, name, "...") orelse name.len;
    const status = std.mem.indexOf(u8, name, " [") orelse name.len;
    return name[0..@min(upstream, status)];
}

fn gitCommonDir(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir" },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return allocator.dupe(u8, "");
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \n\r\t"));
}

fn projectIdFromGitCommonDir(allocator: std.mem.Allocator, root: []const u8, common_dir: []const u8) ![]u8 {
    if (common_dir.len == 0) return allocator.dupe(u8, root);
    if (std.mem.endsWith(u8, common_dir, "/.git")) {
        return allocator.dupe(u8, std.fs.path.dirname(common_dir) orelse root);
    }
    const worktrees_dir = std.fs.path.dirname(common_dir) orelse return allocator.dupe(u8, root);
    const git_dir = std.fs.path.dirname(worktrees_dir) orelse return allocator.dupe(u8, root);
    if (!std.mem.endsWith(u8, git_dir, "/.git")) return allocator.dupe(u8, root);
    return allocator.dupe(u8, std.fs.path.dirname(git_dir) orelse root);
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

test "parses git status branch metadata" {
    try expectStatusBranch("## main\n", "main", false);
    try expectStatusBranch("## main...origin/main [ahead 1]\n M src/main.zig\n", "main", true);
    try expectStatusBranch("## feature.with.dots...origin/feature.with.dots\n", "feature.with.dots", false);
    try expectStatusBranch("## HEAD (no branch)\n", "", false);
    try expectStatusBranch("## No commits yet on main\n?? README.md\n", "main", true);
}

fn expectStatusBranch(status: []const u8, branch: []const u8, dirty: bool) !void {
    const metadata = try parseGitStatus(std.testing.allocator, status);
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(branch, metadata.branch);
    try std.testing.expectEqual(dirty, metadata.dirty);
}
