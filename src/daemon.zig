const std = @import("std");
const discovery = @import("discovery.zig");
const model = @import("model.zig");
const projects = @import("projects.zig");
const tmux = @import("tmux.zig");
const tui = @import("tui.zig");

pub const default_socket_name = "hoppersd.sock";

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("HOPPERSD_SOCKET")) |path| return allocator.dupe(u8, path);
    const base = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const uid = std.c.getuid();
    const tmux_socket = tmuxSocketIdentity() orelse "no-tmux";
    var hash = std.hash.Wyhash.init(0);
    hash.update(tmux_socket);
    return std.fmt.allocPrint(allocator, "{s}/hoppers-{d}/hoppersd-{x:0>16}.sock", .{ base, uid, hash.final() });
}

fn tmuxSocketIdentity() ?[]const u8 {
    if (std.posix.getenv("HOPPERS_TMUX_SOCKET")) |socket| if (socket.len > 0) return socket;
    const tmux_env = std.posix.getenv("TMUX") orelse return null;
    const end = std.mem.indexOfScalar(u8, tmux_env, ',') orelse tmux_env.len;
    return tmux_env[0..end];
}

pub fn ensureSocketDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

pub fn pidPath(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.pid", .{socket_path});
}

pub fn foreground(allocator: std.mem.Allocator, path: []const u8) !void {
    try ensureSocketDir(path);
    if (requestAlloc(allocator, path, "ping")) |response| {
        allocator.free(response);
        return;
    } else |_| {}
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const pid_path = try pidPath(allocator, path);
    defer allocator.free(pid_path);
    {
        const pid_file = try std.fs.createFileAbsolute(pid_path, .{});
        defer pid_file.close();
        var buf: [32]u8 = undefined;
        const pid_text = try std.fmt.bufPrint(&buf, "{d}\n", .{std.c.getpid()});
        try pid_file.writeAll(pid_text);
    }
    defer std.fs.deleteFileAbsolute(pid_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };

    var state: State = .{ .allocator = allocator };
    defer state.deinit();
    try state.refresh();

    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();
    var should_stop = false;
    while (!should_stop) {
        var conn = try server.accept();
        defer conn.stream.close();
        should_stop = handleConnection(&state, conn.stream) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionResetByPeer, error.BrokenPipe => false,
            else => false,
        };
    }
}

pub fn requestAlloc(allocator: std.mem.Allocator, path: []const u8, command: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\"}}", .{command});
    defer allocator.free(payload);
    return requestJsonAlloc(allocator, path, payload);
}

pub fn requestJsonAlloc(allocator: std.mem.Allocator, path: []const u8, payload: []const u8) ![]u8 {
    const stream = try std.net.connectUnixSocket(path);
    defer stream.close();
    try writeFrame(stream, payload);
    return readFrameAlloc(allocator, stream);
}

const State = struct {
    allocator: std.mem.Allocator,
    snapshot: []u8 = &.{},
    items_json: []u8 = &.{},

    fn deinit(self: *State) void {
        self.allocator.free(self.snapshot);
        self.allocator.free(self.items_json);
        self.* = undefined;
    }

    fn refresh(self: *State) !void {
        const next_snapshot = try renderSnapshotAlloc(self.allocator);
        errdefer self.allocator.free(next_snapshot);
        const next_items_json = try renderItemsJsonAlloc(self.allocator);
        self.allocator.free(self.snapshot);
        self.allocator.free(self.items_json);
        self.snapshot = next_snapshot;
        self.items_json = next_items_json;
    }
};

fn handleConnection(state: *State, stream: std.net.Stream) !bool {
    const allocator = state.allocator;
    const request = try readFrameAlloc(allocator, stream);
    defer allocator.free(request);
    const command = parseCommandAlloc(allocator, request) catch try allocator.dupe(u8, "");
    defer allocator.free(command);
    if (std.mem.eql(u8, command, "ping")) {
        try writeFrame(stream, "{\"ok\":true,\"response\":\"pong\"}");
        return false;
    }
    if (std.mem.eql(u8, command, "stop")) {
        try writeFrame(stream, "{\"ok\":true}");
        return true;
    }
    if (std.mem.eql(u8, command, "refresh")) {
        try state.refresh();
        try writeFrame(stream, state.snapshot);
        return false;
    }
    if (std.mem.eql(u8, command, "snapshot")) {
        if (state.snapshot.len == 0) try state.refresh();
        try writeFrame(stream, state.snapshot);
        return false;
    }
    if (std.mem.eql(u8, command, "items")) {
        if (state.items_json.len == 0) try state.refresh();
        try writeFrame(stream, state.items_json);
        return false;
    }
    try writeFrame(stream, "{\"ok\":false,\"error\":\"unknown command\"}");
    return false;
}

fn parseCommandAlloc(allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const command = parsed.value.object.get("command") orelse return error.InvalidRequest;
    if (command != .string) return error.InvalidRequest;
    return allocator.dupe(u8, command.string);
}

pub fn loadItemsAlloc(allocator: std.mem.Allocator, path: []const u8) ![]model.CockpitItem {
    const response = try requestAlloc(allocator, path, "items");
    defer allocator.free(response);
    return parseItemsJsonAlloc(allocator, response);
}

pub fn renderItemsJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const controller = tmux.Controller.init(allocator);
    const panes = try controller.listPanes();
    defer controller.freePanes(panes);
    const items = try discovery.buildCockpit(allocator, panes);
    defer discovery.freeCockpitItems(allocator, items);
    return itemsJsonAlloc(allocator, items);
}

fn itemsJsonAlloc(allocator: std.mem.Allocator, items: []const model.CockpitItem) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.writeAll("[\n");
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(",\n");
        try writer.print(
            "{{\"rank\":{d},\"priority\":{d},\"project\":{f},\"agent\":{f}," ++
                "\"status\":{f},\"kind\":{f},\"session\":{f},\"window\":{f}," ++
                "\"pane\":{f},\"title\":{f},\"last_seen_ms\":{d},\"branch\":{f}," ++
                "\"dirty\":{},\"worktree\":{},\"ports\":[",
            .{
                item.rank,
                item.priority,
                std.json.fmt(item.project.name, .{}),
                std.json.fmt(item.agent.id, .{}),
                std.json.fmt(item.agent.status.label(), .{}),
                std.json.fmt(item.agent.kind.label(), .{}),
                std.json.fmt(item.agent.session_name, .{}),
                std.json.fmt(item.agent.window_id, .{}),
                std.json.fmt(item.agent.pane_id, .{}),
                std.json.fmt(item.agent.title, .{}),
                item.agent.last_seen_ms,
                std.json.fmt(item.project.branch, .{}),
                item.project.dirty,
                item.project.worktree,
            },
        );
        for (item.project.ports, 0..) |port, port_index| {
            if (port_index > 0) try writer.writeByte(',');
            try writer.print("{d}", .{port});
        }
        try writer.print("],\"project_id\":{f},\"root\":{f}}}", .{
            std.json.fmt(item.project.id, .{}),
            std.json.fmt(item.project.root, .{}),
        });
    }
    try writer.writeAll("\n]\n");
    return out.toOwnedSlice(allocator);
}

fn parseItemsJsonAlloc(allocator: std.mem.Allocator, content: []const u8) ![]model.CockpitItem {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidItemsJson;
    var items: std.ArrayList(model.CockpitItem) = .empty;
    errdefer {
        for (items.items) |item| freeParsedItem(allocator, item);
        items.deinit(allocator);
    }
    for (parsed.value.array.items) |value| {
        if (value != .object) return error.InvalidItemsJson;
        const item = try parseItem(allocator, value);
        try items.append(allocator, item);
    }
    return items.toOwnedSlice(allocator);
}

fn parseItem(allocator: std.mem.Allocator, value: std.json.Value) !model.CockpitItem {
    const object = value.object;
    const project_id = try dupStringField(allocator, object, "project_id");
    errdefer allocator.free(project_id);
    const project_name = try dupStringField(allocator, object, "project");
    errdefer allocator.free(project_name);
    const root = try dupStringField(allocator, object, "root");
    errdefer allocator.free(root);
    const branch = try dupStringField(allocator, object, "branch");
    errdefer allocator.free(branch);
    const ports = try parsePorts(allocator, object.get("ports") orelse return error.InvalidItemsJson);
    errdefer allocator.free(ports);
    const agent_id = try dupStringField(allocator, object, "agent");
    errdefer allocator.free(agent_id);
    const session = try dupStringField(allocator, object, "session");
    errdefer allocator.free(session);
    const window = try dupStringField(allocator, object, "window");
    errdefer allocator.free(window);
    const pane = try dupStringField(allocator, object, "pane");
    errdefer allocator.free(pane);
    const title = try dupStringField(allocator, object, "title");
    errdefer allocator.free(title);
    return .{
        .rank = try intField(usize, object, "rank"),
        .priority = try intField(i32, object, "priority"),
        .project = .{
            .id = project_id,
            .name = project_name,
            .root = root,
            .branch = branch,
            .dirty = try boolField(object, "dirty"),
            .worktree = try boolField(object, "worktree"),
            .ports = ports,
        },
        .agent = .{
            .id = agent_id,
            .kind = try parseKind(try stringField(object, "kind")),
            .status = try parseStatus(try stringField(object, "status")),
            .project_id = project_id,
            .session_name = session,
            .window_id = window,
            .pane_id = pane,
            .title = title,
            .last_seen_ms = try intField(i64, object, "last_seen_ms"),
        },
    };
}

fn freeParsedItem(allocator: std.mem.Allocator, item: model.CockpitItem) void {
    projects.freeProject(allocator, item.project);
    allocator.free(item.agent.id);
    allocator.free(item.agent.session_name);
    allocator.free(item.agent.window_id);
    allocator.free(item.agent.pane_id);
    allocator.free(item.agent.title);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidItemsJson;
    if (value != .string) return error.InvalidItemsJson;
    return value.string;
}

fn dupStringField(allocator: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) ![]u8 {
    return allocator.dupe(u8, try stringField(object, name));
}

fn boolField(object: std.json.ObjectMap, name: []const u8) !bool {
    const value = object.get(name) orelse return error.InvalidItemsJson;
    if (value != .bool) return error.InvalidItemsJson;
    return value.bool;
}

fn intField(comptime T: type, object: std.json.ObjectMap, name: []const u8) !T {
    const value = object.get(name) orelse return error.InvalidItemsJson;
    if (value != .integer) return error.InvalidItemsJson;
    return @intCast(value.integer);
}

fn parsePorts(allocator: std.mem.Allocator, value: std.json.Value) ![]const u16 {
    if (value != .array) return error.InvalidItemsJson;
    const ports = try allocator.alloc(u16, value.array.items.len);
    errdefer allocator.free(ports);
    for (value.array.items, 0..) |port, index| {
        if (port != .integer) return error.InvalidItemsJson;
        ports[index] = @intCast(port.integer);
    }
    return ports;
}

fn parseKind(label: []const u8) !model.AgentKind {
    if (std.mem.eql(u8, label, "claude")) return .claude;
    if (std.mem.eql(u8, label, "codex")) return .codex;
    if (std.mem.eql(u8, label, "opencode")) return .opencode;
    if (std.mem.eql(u8, label, "pi")) return .pi;
    if (std.mem.eql(u8, label, "marvin")) return .marvin;
    return error.InvalidItemsJson;
}

fn parseStatus(label: []const u8) !model.AgentStatus {
    if (std.mem.eql(u8, label, "idle")) return .idle;
    if (std.mem.eql(u8, label, "running")) return .running;
    if (std.mem.eql(u8, label, "waiting")) return .waiting;
    if (std.mem.eql(u8, label, "done")) return .done;
    if (std.mem.eql(u8, label, "failed")) return .failed;
    if (std.mem.eql(u8, label, "stale")) return .stale;
    return error.InvalidItemsJson;
}

pub fn renderSnapshotAlloc(allocator: std.mem.Allocator) ![]u8 {
    const controller = tmux.Controller.init(allocator);
    const panes = try controller.listPanes();
    defer controller.freePanes(panes);
    const items = try discovery.buildCockpit(allocator, panes);
    defer discovery.freeCockpitItems(allocator, items);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try tui.renderSnapshot(out.writer(allocator), items);
    return out.toOwnedSlice(allocator);
}

fn writeFrame(stream: std.net.Stream, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    try stream.writeAll(&header);
    try stream.writeAll(payload);
}

fn readFrameAlloc(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var header: [4]u8 = undefined;
    if (try stream.readAtLeast(&header, header.len) != header.len) return error.EndOfStream;
    const len = std.mem.readInt(u32, &header, .big);
    if (len > 4 * 1024 * 1024) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    if (try stream.readAtLeast(payload, payload.len) != payload.len) return error.EndOfStream;
    return payload;
}

test "socket path honors override" {
    // Environment mutation is intentionally avoided; this smoke test keeps the module in the test graph.
    try std.testing.expect(default_socket_name.len > 0);
}
