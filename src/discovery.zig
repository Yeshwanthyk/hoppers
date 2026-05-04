const std = @import("std");
const model = @import("model.zig");
const projects = @import("projects.zig");
const ranking = @import("ranking.zig");
const tmux = @import("tmux.zig");

pub fn buildCockpit(allocator: std.mem.Allocator, panes: []const model.TmuxPane) ![]model.CockpitItem {
    var items: std.ArrayList(model.CockpitItem) = .empty;
    var detector: PaneAgentDetector = .{ .allocator = allocator };
    defer detector.deinit();
    errdefer {
        for (items.items) |item| freeCockpitItem(allocator, item);
        items.deinit(allocator);
    }

    for (panes) |pane| {
        const item = (try buildCockpitItem(allocator, &detector, pane)) orelse continue;
        items.append(allocator, item) catch |err| {
            freeCockpitItem(allocator, item);
            return err;
        };
    }

    const owned = try items.toOwnedSlice(allocator);
    ranking.assignRanks(owned);
    return owned;
}

pub fn freeCockpitItems(allocator: std.mem.Allocator, items: []model.CockpitItem) void {
    for (items) |item| freeCockpitItem(allocator, item);
    allocator.free(items);
}

fn buildCockpitItem(
    allocator: std.mem.Allocator,
    detector: *PaneAgentDetector,
    pane: model.TmuxPane,
) !?model.CockpitItem {
    const kind = detector.detectPaneAgentKind(pane);
    if (kind == .unknown) return null;

    const project = try projects.inferProject(allocator, pane.current_path);
    errdefer projects.freeProject(allocator, project);

    const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind.label(), pane.pane_id });
    errdefer allocator.free(id);

    const raw_title = activityTitle(pane);
    const fallback_title = trimActivityTitle(raw_title, project.name);
    const captured_title = captureActivity(allocator, pane.pane_id) catch fallback_title;
    const title = if (captured_title.len > 0) captured_title else fallback_title;
    const status = inferStatus(title);
    defer if (title.ptr != fallback_title.ptr and title.ptr != raw_title.ptr) allocator.free(title);

    const owned_session_name = try allocator.dupe(u8, pane.session_name);
    errdefer allocator.free(owned_session_name);
    const owned_window_id = try allocator.dupe(u8, pane.window_id);
    errdefer allocator.free(owned_window_id);
    const owned_pane_id = try allocator.dupe(u8, pane.pane_id);
    errdefer allocator.free(owned_pane_id);
    const owned_title = try allocator.dupe(u8, title);
    errdefer allocator.free(owned_title);

    const agent: model.AgentInstance = .{
        .id = id,
        .kind = kind,
        .status = status,
        .project_id = project.id,
        .session_name = owned_session_name,
        .window_id = owned_window_id,
        .pane_id = owned_pane_id,
        .title = owned_title,
        .last_seen_ms = std.time.milliTimestamp(),
    };
    const priority = ranking.agentPriority(project, agent);
    return .{ .rank = 0, .priority = priority, .project = project, .agent = agent };
}

fn captureActivity(allocator: std.mem.Allocator, pane_id: []const u8) ![]u8 {
    const controller = tmux.Controller.init(allocator);
    const capture = try controller.capturePane(pane_id);
    defer allocator.free(capture);
    const line = lastMeaningfulLine(capture) orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, line);
}

fn lastMeaningfulLine(capture: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, capture, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "hoppers")) continue;
        if (std.mem.indexOf(u8, trimmed, "Session compacted") != null) continue;
        result = trimmed;
    }
    return result;
}

fn activityTitle(pane: model.TmuxPane) []const u8 {
    if (pane.title.len > 0) return pane.title;
    if (pane.start_command.len > 0) return pane.start_command;
    return pane.current_command;
}

fn trimActivityTitle(title: []const u8, project_name: []const u8) []const u8 {
    var last_part = title;
    var parts = std.mem.splitSequence(u8, title, "·");
    while (parts.next()) |part| last_part = std.mem.trim(u8, part, " \t");
    if (last_part.len > 0 and !std.mem.eql(u8, last_part, project_name)) return last_part;
    if (std.mem.eql(u8, title, project_name)) return "";
    return title;
}

fn inferStatus(title: []const u8) model.AgentStatus {
    var lower_buf: [256]u8 = undefined;
    const n = @min(title.len, lower_buf.len);
    const lower = lower_buf[0..n];
    for (title[0..n], 0..) |char, i| lower[i] = std.ascii.toLower(char);
    if (contains(lower, "error") or contains(lower, "failed")) return .failed;
    if (contains(lower, "complete") or contains(lower, "done")) return .done;
    if (contains(lower, "ready") or contains(lower, "waiting")) return .waiting;
    if (contains(lower, "executing") or contains(lower, "running")) return .running;
    return .running;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const PaneAgentDetector = struct {
    allocator: std.mem.Allocator,
    processes: ?[]ProcessInfo = null,
    ps_output: ?[]u8 = null,

    fn deinit(self: *PaneAgentDetector) void {
        if (self.processes) |processes| self.allocator.free(processes);
        if (self.ps_output) |ps_output| self.allocator.free(ps_output);
        self.* = undefined;
    }

    fn detectPaneAgentKind(self: *PaneAgentDetector, pane: model.TmuxPane) model.AgentKind {
        const direct = model.detectAgentKind(pane.current_command, pane.start_command, pane.title);
        if (direct != .unknown) return direct;
        return self.detectDescendantAgentKind(pane.pane_pid) catch .unknown;
    }

    fn detectDescendantAgentKind(self: *PaneAgentDetector, root_pid: u32) !model.AgentKind {
        const processes = try self.loadProcesses();
        for (processes) |process| {
            if (!isDescendantProcess(processes, process, root_pid)) continue;
            const kind = model.detectAgentKind(process.command, "", "");
            if (kind != .unknown) return kind;
        }
        return .unknown;
    }

    fn loadProcesses(self: *PaneAgentDetector) ![]const ProcessInfo {
        if (self.processes) |processes| return processes;
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "ps", "-axo", "pid=,ppid=,comm=" },
            .max_output_bytes = 1024 * 1024,
        });
        defer self.allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            self.processes = try self.allocator.alloc(ProcessInfo, 0);
            return self.processes.?;
        }
        errdefer self.allocator.free(result.stdout);

        var processes: std.ArrayList(ProcessInfo) = .empty;
        errdefer processes.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const process = parseProcessLine(line) orelse continue;
            try processes.append(self.allocator, process);
        }

        self.processes = try processes.toOwnedSlice(self.allocator);
        self.ps_output = result.stdout;
        return self.processes.?;
    }
};

const ProcessInfo = struct {
    pid: u32,
    ppid: u32,
    command: []const u8,
};

fn parseProcessLine(line: []const u8) ?ProcessInfo {
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    const pid_text = parts.next() orelse return null;
    const ppid_text = parts.next() orelse return null;
    const command = parts.next() orelse return null;
    return .{
        .pid = std.fmt.parseInt(u32, pid_text, 10) catch return null,
        .ppid = std.fmt.parseInt(u32, ppid_text, 10) catch return null,
        .command = command,
    };
}

fn isDescendantProcess(processes: []const ProcessInfo, process: ProcessInfo, root_pid: u32) bool {
    var ppid = process.ppid;
    var depth: usize = 0;
    while (ppid != 0 and depth < processes.len) : (depth += 1) {
        if (ppid == root_pid) return true;
        ppid = parentPid(processes, ppid) orelse return false;
    }
    return false;
}

fn parentPid(processes: []const ProcessInfo, pid: u32) ?u32 {
    for (processes) |process| {
        if (process.pid == pid) return process.ppid;
    }
    return null;
}

fn freeCockpitItem(allocator: std.mem.Allocator, item: model.CockpitItem) void {
    projects.freeProject(allocator, item.project);
    allocator.free(item.agent.id);
    allocator.free(item.agent.session_name);
    allocator.free(item.agent.window_id);
    allocator.free(item.agent.pane_id);
    allocator.free(item.agent.title);
}

test "builds cockpit from agent panes" {
    const panes = [_]model.TmuxPane{.{
        .session_name = "hoppers",
        .window_id = "@1",
        .pane_id = "%1",
        .pane_pid = 1,
        .current_command = "sleep",
        .start_command = "exec -a claude sleep 600",
        .current_path = "/tmp/hoppers",
        .title = "Claude task",
    }};
    const items = try buildCockpit(std.testing.allocator, &panes);
    defer freeCockpitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(model.AgentKind.claude, items[0].agent.kind);
}
