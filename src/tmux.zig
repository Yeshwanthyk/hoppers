const std = @import("std");
const model = @import("model.zig");
const sanitize = @import("sanitize.zig");

const field_separator = "‹HOP›";
const pane_format = "#{session_name}" ++ field_separator ++
    "#{window_id}" ++ field_separator ++
    "#{pane_id}" ++ field_separator ++
    "#{pane_pid}" ++ field_separator ++
    "#{pane_current_command}" ++ field_separator ++
    "#{pane_start_command}" ++ field_separator ++
    "#{pane_current_path}" ++ field_separator ++
    "#{pane_title}";

pub const Controller = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return .{ .allocator = allocator };
    }

    pub fn listPanes(self: Controller) ![]model.TmuxPane {
        const output = try self.run(&.{ "tmux", "list-panes", "-a", "-F", pane_format });
        defer self.allocator.free(output);

        var panes: std.ArrayList(model.TmuxPane) = .empty;
        errdefer {
            for (panes.items) |pane| freePane(self.allocator, pane);
            panes.deinit(self.allocator);
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const pane = try parsePane(self.allocator, line);
            panes.append(self.allocator, pane) catch |err| {
                freePane(self.allocator, pane);
                return err;
            };
        }
        return panes.toOwnedSlice(self.allocator);
    }

    pub fn activePaneId(self: Controller) ![]u8 {
        const output = try self.run(&.{ "tmux", "display-message", "-p", "#{pane_id}" });
        defer self.allocator.free(output);
        const trimmed = std.mem.trim(u8, output, " \n\r\t");
        return self.allocator.dupe(u8, trimmed);
    }

    pub fn selectPane(self: Controller, pane_id: []const u8) !void {
        const window_id = try self.run(&.{ "tmux", "display-message", "-p", "-t", pane_id, "#{window_id}" });
        defer self.allocator.free(window_id);
        const trimmed_window_id = std.mem.trim(u8, window_id, " \n\r\t");
        if (trimmed_window_id.len > 0) {
            try self.runVoid(&.{ "tmux", "select-window", "-t", trimmed_window_id });
        }
        try self.runVoid(&.{ "tmux", "select-pane", "-t", pane_id });
    }

    pub fn switchSession(self: Controller, session_name: []const u8) !void {
        if (self.hasAttachedClient()) {
            try self.runVoid(&.{ "tmux", "switch-client", "-t", session_name });
            return;
        }
        try self.runVoid(&.{ "tmux", "has-session", "-t", session_name });
    }

    fn hasAttachedClient(self: Controller) bool {
        const output = self.run(&.{ "tmux", "list-clients", "-F", "#{client_tty}" }) catch return false;
        defer self.allocator.free(output);
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \n\r\t").len > 0) return true;
        }
        return false;
    }

    pub fn freePanes(self: Controller, panes: []model.TmuxPane) void {
        for (panes) |pane| freePane(self.allocator, pane);
        self.allocator.free(panes);
    }

    fn run(self: Controller, argv: []const []const u8) ![]u8 {
        const actual_argv = try self.tmuxArgv(argv);
        defer if (actual_argv.ptr != argv.ptr) self.allocator.free(actual_argv);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = actual_argv,
            .max_output_bytes = 1024 * 1024,
        });
        defer self.allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            return error.CommandFailed;
        }
        return result.stdout;
    }

    fn runVoid(self: Controller, argv: []const []const u8) !void {
        const output = try self.run(argv);
        self.allocator.free(output);
    }

    fn tmuxArgv(self: Controller, argv: []const []const u8) ![]const []const u8 {
        if (argv.len == 0 or !std.mem.eql(u8, argv[0], "tmux")) return argv;
        const socket = std.posix.getenv("HOPPERS_TMUX_SOCKET") orelse return argv;
        if (socket.len == 0) return argv;
        var actual = try self.allocator.alloc([]const u8, argv.len + 2);
        actual[0] = "tmux";
        actual[1] = "-S";
        actual[2] = socket;
        @memcpy(actual[3..], argv[1..]);
        return actual;
    }
};

pub fn parsePane(allocator: std.mem.Allocator, line: []const u8) !model.TmuxPane {
    var parts = std.mem.splitSequence(u8, line, field_separator);
    const session_name = parts.next() orelse return error.InvalidPaneLine;
    const window_id = parts.next() orelse return error.InvalidPaneLine;
    const pane_id = parts.next() orelse return error.InvalidPaneLine;
    const pid_text = parts.next() orelse return error.InvalidPaneLine;
    const command = parts.next() orelse return error.InvalidPaneLine;
    const start_command = parts.next() orelse return error.InvalidPaneLine;
    const path = parts.next() orelse return error.InvalidPaneLine;
    const title = parts.rest();

    const pane_pid = try std.fmt.parseInt(u32, pid_text, 10);
    const owned_session_name = try allocator.dupe(u8, session_name);
    errdefer allocator.free(owned_session_name);
    const owned_window_id = try allocator.dupe(u8, window_id);
    errdefer allocator.free(owned_window_id);
    const owned_pane_id = try allocator.dupe(u8, pane_id);
    errdefer allocator.free(owned_pane_id);
    const owned_command = try sanitize.cleanAlloc(allocator, command);
    errdefer allocator.free(owned_command);
    const owned_start_command = try sanitize.cleanAlloc(allocator, start_command);
    errdefer allocator.free(owned_start_command);
    const owned_path = try sanitize.cleanAlloc(allocator, path);
    errdefer allocator.free(owned_path);
    const owned_title = try sanitize.cleanAlloc(allocator, title);
    errdefer allocator.free(owned_title);

    return .{
        .session_name = owned_session_name,
        .window_id = owned_window_id,
        .pane_id = owned_pane_id,
        .pane_pid = pane_pid,
        .current_command = owned_command,
        .start_command = owned_start_command,
        .current_path = owned_path,
        .title = owned_title,
    };
}

pub fn freePane(allocator: std.mem.Allocator, pane: model.TmuxPane) void {
    allocator.free(pane.session_name);
    allocator.free(pane.window_id);
    allocator.free(pane.pane_id);
    allocator.free(pane.current_command);
    allocator.free(pane.start_command);
    allocator.free(pane.current_path);
    allocator.free(pane.title);
}

test "parse tmux pane line" {
    const allocator = std.testing.allocator;
    const line = "hoppers‹HOP›@1‹HOP›%2‹HOP›123‹HOP›" ++
        "claude‹HOP›exec -a claude sleep 600‹HOP›/tmp/hoppers‹HOP›Claude task";
    const pane = try parsePane(allocator, line);
    defer freePane(allocator, pane);
    try std.testing.expectEqualStrings("hoppers", pane.session_name);
    try std.testing.expectEqualStrings("%2", pane.pane_id);
    try std.testing.expectEqual(@as(u32, 123), pane.pane_pid);
}
