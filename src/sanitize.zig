const std = @import("std");

pub fn cleanAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte == 0x1b) {
            i = skipEscape(input, i + 1);
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            if (byte == '\t') try out.append(allocator, ' ');
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.append(allocator, '?');
            i += 1;
            continue;
        };
        if (i + len > input.len) {
            try out.append(allocator, '?');
            break;
        }
        if (!std.unicode.utf8ValidateSlice(input[i .. i + len])) {
            try out.append(allocator, '?');
            i += 1;
            continue;
        }
        try out.appendSlice(allocator, input[i .. i + len]);
        i += len;
    }

    return out.toOwnedSlice(allocator);
}

fn skipEscape(input: []const u8, start: usize) usize {
    if (start >= input.len) return start;
    if (input[start] == ']') {
        var i = start + 1;
        while (i < input.len) : (i += 1) {
            if (input[i] == 0x07) return i + 1;
            if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') return i + 2;
        }
        return input.len;
    }
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] >= 0x40 and input[i] <= 0x7e) return i + 1;
    }
    return input.len;
}

test "sanitizes control and invalid bytes" {
    const allocator = std.testing.allocator;
    const cleaned = try cleanAlloc(allocator, "ok\x1b]2;bad\x07\xff\n");
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings("ok?", cleaned);
}
