const std = @import("std");
const model = @import("model.zig");
const pi_tasks = @import("pi_tasks.zig");
const projects = @import("projects.zig");
const ranking = @import("ranking.zig");

pub fn buildCockpit(allocator: std.mem.Allocator, panes: []const model.TmuxPane) ![]model.CockpitItem {
    var items: std.ArrayList(model.CockpitItem) = .empty;
    var context: DiscoveryContext = .{
        .allocator = allocator,
        .project_cache = projects.ProjectCache.init(allocator),
        .detector = .{ .allocator = allocator },
    };
    defer context.deinit();
    errdefer {
        for (items.items) |item| freeCockpitItem(allocator, item);
        items.deinit(allocator);
    }

    for (panes) |pane| {
        const item = (try buildCockpitItem(allocator, &context, pane)) orelse continue;
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
    context: *DiscoveryContext,
    pane: model.TmuxPane,
) !?model.CockpitItem {
    const kind = context.detector.detectPaneAgentKind(pane);
    if (kind == .unknown) return null;

    var project = try context.project_cache.infer(pane.current_path);
    errdefer projects.freeProject(allocator, project);
    const ports = try context.detector.detectPorts(pane.pane_pid);
    allocator.free(project.ports);
    project.ports = ports;

    const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind.label(), pane.pane_id });
    errdefer allocator.free(id);

    const raw_title = activityTitle(pane);
    var status = paneStatus(pane);
    var semantic_title: ?[]u8 = null;
    if (kind == .pi) {
        if (try pi_tasks.summarizeForProject(allocator, project.root)) |summary| {
            status = summary.status;
            semantic_title = summary.title;
        }
    }
    defer if (semantic_title) |title| allocator.free(title);
    const title = semantic_title orelse trimActivityTitle(raw_title, project.name);

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

fn activityTitle(pane: model.TmuxPane) []const u8 {
    if (pane.title.len > 0) return pane.title;
    if (pane.current_command.len > 0) return pane.current_command;
    return "";
}

fn trimActivityTitle(title: []const u8, project_name: []const u8) []const u8 {
    var last_part = title;
    var parts = std.mem.splitSequence(u8, title, "·");
    while (parts.next()) |part| last_part = std.mem.trim(u8, part, " \t");
    if (last_part.len > 0 and !std.mem.eql(u8, last_part, project_name)) return last_part;
    if (std.mem.eql(u8, title, project_name)) return "";
    return title;
}

fn paneStatus(pane: model.TmuxPane) model.AgentStatus {
    _ = pane;
    return .idle;
}

test "raw pane text cannot infer active or terminal status" {
    const pane: model.TmuxPane = .{
        .session_name = "s",
        .window_id = "@1",
        .pane_id = "%1",
        .pane_pid = 1,
        .current_command = "running failed done complete error executing waiting ready",
        .start_command = "failed",
        .current_path = "/tmp",
        .title = "running failed done complete error executing waiting ready",
    };

    try std.testing.expectEqual(model.AgentStatus.idle, paneStatus(pane));
}

test "activity title ignores captured output and prefers pane metadata" {
    const titled: model.TmuxPane = .{
        .session_name = "s",
        .window_id = "@1",
        .pane_id = "%1",
        .pane_pid = 1,
        .current_command = "codex",
        .start_command = "claude --dangerously-skip-permissions",
        .current_path = "/tmp",
        .title = "semantic title",
    };
    const command_only: model.TmuxPane = .{
        .session_name = "s",
        .window_id = "@1",
        .pane_id = "%1",
        .pane_pid = 1,
        .current_command = "codex",
        .start_command = "claude --dangerously-skip-permissions",
        .current_path = "/tmp",
        .title = "",
    };

    try std.testing.expectEqualStrings("semantic title", activityTitle(titled));
    try std.testing.expectEqualStrings("codex", activityTitle(command_only));
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const DiscoveryContext = struct {
    allocator: std.mem.Allocator,
    project_cache: projects.ProjectCache,
    detector: PaneAgentDetector,

    fn deinit(self: *DiscoveryContext) void {
        self.detector.deinit();
        self.project_cache.deinit();
        self.* = undefined;
    }
};

const PaneAgentDetector = struct {
    allocator: std.mem.Allocator,
    processes: ?[]ProcessInfo = null,
    parent_pids: ?std.AutoHashMap(u32, u32) = null,
    ps_output: ?[]u8 = null,
    listening_ports: ?[]PidPort = null,

    fn deinit(self: *PaneAgentDetector) void {
        if (self.processes) |processes| self.allocator.free(processes);
        if (self.parent_pids) |*parent_pids| parent_pids.deinit();
        if (self.ps_output) |ps_output| self.allocator.free(ps_output);
        if (self.listening_ports) |listening_ports| self.allocator.free(listening_ports);
        self.* = undefined;
    }

    fn detectPaneAgentKind(self: *PaneAgentDetector, pane: model.TmuxPane) model.AgentKind {
        const direct = model.detectAgentKind(pane.current_command, pane.start_command, pane.title);
        if (direct != .unknown) return direct;
        return self.detectDescendantAgentKind(pane.pane_pid) catch .unknown;
    }

    fn detectDescendantAgentKind(self: *PaneAgentDetector, root_pid: u32) !model.AgentKind {
        const processes = try self.loadProcesses();
        try self.loadParentPids();
        for (processes) |process| {
            if (!self.isDescendantProcess(process, root_pid)) continue;
            const kind = model.detectAgentKind(process.command, "", "");
            if (kind != .unknown) return kind;
        }
        return .unknown;
    }

    fn detectPorts(self: *PaneAgentDetector, root_pid: u32) ![]const u16 {
        _ = try self.loadProcesses();
        try self.loadParentPids();
        const listening_ports = self.loadListeningPorts() catch return self.allocator.alloc(u16, 0);
        var ports: std.ArrayList(u16) = .empty;
        errdefer ports.deinit(self.allocator);
        for (listening_ports) |pid_port| {
            const matches_root = pid_port.pid == root_pid;
            const matches_child = !matches_root and self.isDescendantPid(pid_port.pid, root_pid);
            if (!matches_root and !matches_child) continue;
            if (!containsPort(ports.items, pid_port.port)) try ports.append(self.allocator, pid_port.port);
        }
        std.mem.sort(u16, ports.items, {}, std.sort.asc(u16));
        return ports.toOwnedSlice(self.allocator);
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

    fn loadParentPids(self: *PaneAgentDetector) !void {
        if (self.parent_pids != null) return;

        const processes = try self.loadProcesses();
        var parent_pids = std.AutoHashMap(u32, u32).init(self.allocator);
        errdefer parent_pids.deinit();
        try parent_pids.ensureTotalCapacity(@intCast(processes.len));
        for (processes) |process| parent_pids.putAssumeCapacity(process.pid, process.ppid);

        self.parent_pids = parent_pids;
    }

    fn isDescendantProcess(self: *PaneAgentDetector, process: ProcessInfo, root_pid: u32) bool {
        return self.isDescendantPid(process.pid, root_pid);
    }

    fn isDescendantPid(self: *PaneAgentDetector, pid: u32, root_pid: u32) bool {
        const parent_pids = self.parent_pids orelse return false;
        var ppid = parent_pids.get(pid) orelse return false;
        var depth: usize = 0;
        while (ppid != 0 and depth < parent_pids.count()) : (depth += 1) {
            if (ppid == root_pid) return true;
            ppid = parent_pids.get(ppid) orelse return false;
        }
        return false;
    }

    fn loadListeningPorts(self: *PaneAgentDetector) ![]const PidPort {
        if (self.listening_ports) |listening_ports| return listening_ports;
        self.listening_ports = try listListeningPorts(self.allocator);
        return self.listening_ports.?;
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

const PidPort = struct {
    pid: u32,
    port: u16,
};

fn listListeningPorts(allocator: std.mem.Allocator) ![]PidPort {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn" },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return allocator.alloc(PidPort, 0);

    var ports: std.ArrayList(PidPort) = .empty;
    errdefer ports.deinit(allocator);
    var current_pid: ?u32 = null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (parseLsofPid(line)) |pid| {
            current_pid = pid;
            continue;
        }
        const pid = current_pid orelse continue;
        const port = parseLsofPort(line) orelse continue;
        if (!containsPidPort(ports.items, pid, port)) try ports.append(allocator, .{ .pid = pid, .port = port });
    }
    return ports.toOwnedSlice(allocator);
}

fn parseLsofPid(line: []const u8) ?u32 {
    if (line.len < 2 or line[0] != 'p') return null;
    return std.fmt.parseInt(u32, line[1..], 10) catch null;
}

fn parseLsofPort(line: []const u8) ?u16 {
    if (line.len < 2 or line[0] != 'n') return null;
    const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse return null;
    var end = colon + 1;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == colon + 1) return null;
    return std.fmt.parseInt(u16, line[colon + 1 .. end], 10) catch null;
}

fn containsPort(ports: []const u16, port: u16) bool {
    for (ports) |existing| {
        if (existing == port) return true;
    }
    return false;
}

fn containsPidPort(ports: []const PidPort, pid: u32, port: u16) bool {
    for (ports) |existing| {
        if (existing.pid == pid and existing.port == port) return true;
    }
    return false;
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
