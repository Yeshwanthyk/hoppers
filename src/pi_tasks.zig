const std = @import("std");
const model = @import("model.zig");

pub const Summary = struct {
    status: model.AgentStatus,
    title: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        self.* = undefined;
    }
};

pub fn summarizeForProject(allocator: std.mem.Allocator, project_root: []const u8) !?Summary {
    var tasks_dir = std.fs.openDirAbsolute(project_root, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    tasks_dir.close();

    var pi_dir = std.fs.openDirAbsolute(project_root, .{ .iterate = true }) catch return null;
    defer pi_dir.close();
    var dot_pi = pi_dir.openDir(".pi/tasks", .{ .iterate = true }) catch return null;
    defer dot_pi.close();

    var result: Summary = .{ .status = .idle, .title = try allocator.dupe(u8, "") };
    errdefer result.deinit(allocator);
    var pending_count: usize = 0;

    var iter = dot_pi.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const content = dot_pi.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
        defer allocator.free(content);
        try summarizeContent(allocator, content, &result, &pending_count);
    }

    if (result.status == .waiting and pending_count > 0) {
        allocator.free(result.title);
        result.title = try std.fmt.allocPrint(allocator, "{d} pending tasks", .{pending_count});
        result.status = .waiting;
    }

    if (result.title.len == 0) {
        if (result.status == .done) {
            result.title = try allocator.dupe(u8, "all tasks completed");
            return result;
        }
        result.deinit(allocator);
        return null;
    }
    return result;
}

fn summarizeContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    result: *Summary,
    pending_count: *usize,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
    const tasks_value = root.get("tasks") orelse return;
    if (tasks_value != .array) return;

    for (tasks_value.array.items) |task| {
        if (task != .object) continue;
        const status_value = task.object.get("status") orelse continue;
        if (status_value != .string) continue;
        const status = status_value.string;
        if (std.mem.eql(u8, status, "in_progress")) {
            const text = taskText(task, "activeForm") orelse taskText(task, "subject") orelse "active task";
            try replaceTitle(allocator, result, text);
            result.status = .running;
            return;
        }
        if (std.mem.eql(u8, status, "failed")) {
            if (result.status != .running) {
                const text = taskText(task, "subject") orelse "failed task";
                try replaceTitle(allocator, result, text);
                result.status = .failed;
            }
            continue;
        }
        if (std.mem.eql(u8, status, "completed")) {
            if (result.status == .idle) result.status = .done;
            continue;
        }
        if (std.mem.eql(u8, status, "pending")) {
            pending_count.* += 1;
            if (result.status == .idle or result.status == .done) result.status = .waiting;
        }
    }
}

fn taskText(task: std.json.Value, key: []const u8) ?[]const u8 {
    const value = task.object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn replaceTitle(allocator: std.mem.Allocator, result: *Summary, text: []const u8) !void {
    const owned = try allocator.dupe(u8, text);
    allocator.free(result.title);
    result.title = owned;
}

test "summarizes pi active form before subject" {
    const content =
        \\{"tasks":[{"subject":"Do thing","status":"in_progress","activeForm":"Doing thing"}]}
    ;
    var summary: Summary = .{ .status = .idle, .title = try std.testing.allocator.dupe(u8, "") };
    defer summary.deinit(std.testing.allocator);
    var pending: usize = 0;
    try summarizeContent(std.testing.allocator, content, &summary, &pending);
    try std.testing.expectEqual(model.AgentStatus.running, summary.status);
    try std.testing.expectEqualStrings("Doing thing", summary.title);
}

test "valid non-object json is ignored" {
    var summary: Summary = .{ .status = .idle, .title = try std.testing.allocator.dupe(u8, "") };
    defer summary.deinit(std.testing.allocator);
    var pending: usize = 0;
    try summarizeContent(std.testing.allocator, "[]", &summary, &pending);
    try std.testing.expectEqual(model.AgentStatus.idle, summary.status);
}

test "summarizes pending count" {
    const content =
        \\{"tasks":[{"subject":"A","status":"pending"},{"subject":"B","status":"pending"}]}
    ;
    var summary: Summary = .{ .status = .idle, .title = try std.testing.allocator.dupe(u8, "") };
    defer summary.deinit(std.testing.allocator);
    var pending: usize = 0;
    try summarizeContent(std.testing.allocator, content, &summary, &pending);
    try std.testing.expectEqual(model.AgentStatus.waiting, summary.status);
    try std.testing.expectEqual(@as(usize, 2), pending);
}

test "summarizes failed task" {
    const content =
        \\{"tasks":[{"subject":"Broken","status":"failed"},{"subject":"Queued","status":"pending"}]}
    ;
    var summary: Summary = .{ .status = .idle, .title = try std.testing.allocator.dupe(u8, "") };
    defer summary.deinit(std.testing.allocator);
    var pending: usize = 0;
    try summarizeContent(std.testing.allocator, content, &summary, &pending);
    try std.testing.expectEqual(model.AgentStatus.failed, summary.status);
    try std.testing.expectEqualStrings("Broken", summary.title);
}

test "summarizes completed tasks as done" {
    const content =
        \\{"tasks":[{"subject":"Done","status":"completed"}]}
    ;
    var summary: Summary = .{ .status = .idle, .title = try std.testing.allocator.dupe(u8, "") };
    defer summary.deinit(std.testing.allocator);
    var pending: usize = 0;
    try summarizeContent(std.testing.allocator, content, &summary, &pending);
    if (summary.title.len == 0 and summary.status == .done) try replaceTitle(
        std.testing.allocator,
        &summary,
        "all tasks completed",
    );
    try std.testing.expectEqual(model.AgentStatus.done, summary.status);
    try std.testing.expectEqualStrings("all tasks completed", summary.title);
}

test "pi task state precedence is running failed waiting done" {
    const content =
        \\{"tasks":[
        \\  {"subject":"Done","status":"completed"},
        \\  {"subject":"Queued","status":"pending"},
        \\  {"subject":"Broken","status":"failed"},
        \\  {"subject":"Run","status":"in_progress","activeForm":"Running"}
        \\]}
    ;
    var summary: Summary = .{ .status = .idle, .title = try std.testing.allocator.dupe(u8, "") };
    defer summary.deinit(std.testing.allocator);
    var pending: usize = 0;
    try summarizeContent(std.testing.allocator, content, &summary, &pending);
    try std.testing.expectEqual(model.AgentStatus.running, summary.status);
    try std.testing.expectEqualStrings("Running", summary.title);
    try std.testing.expectEqual(@as(usize, 1), pending);
}
