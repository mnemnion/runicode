const std = @import("std");
const testing = std.testing;

pub const Range = struct {
    first: u21,
    last: u21,
};

pub const FieldList = struct {
    items: []const []const u8,

    pub fn deinit(list: FieldList, allocator: std.mem.Allocator) void {
        allocator.free(list.items);
    }
};

pub fn parseCodepoint(text: []const u8) !u21 {
    return std.fmt.parseInt(u21, text, 16);
}

pub fn parseCodepointRange(text: []const u8) !Range {
    if (std.mem.indexOf(u8, text, "..")) |dots| {
        return .{
            .first = try parseCodepoint(text[0..dots]),
            .last = try parseCodepoint(text[dots + 2 ..]),
        };
    }
    const point = try parseCodepoint(text);
    return .{ .first = point, .last = point };
}

pub fn parseScalarSequence(allocator: std.mem.Allocator, text: []const u8) ![]u21 {
    var list: std.ArrayList(u21) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |part| {
        try list.append(allocator, try parseCodepoint(part));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn fields(allocator: std.mem.Allocator, line: []const u8) !FieldList {
    const uncommented = if (std.mem.indexOfScalar(u8, line, '#')) |hash| line[0..hash] else line;
    const trimmed = std.mem.trim(u8, uncommented, " \t\r\n");
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    while (it.next()) |field| {
        try list.append(allocator, std.mem.trim(u8, field, " \t\r\n"));
    }
    return .{ .items = try list.toOwnedSlice(allocator) };
}

test "parse codepoint parses hex scalar" {
    try testing.expectEqual(@as(u21, 0x1F600), try parseCodepoint("1F600"));
}

test "parse codepoint range parses point and range" {
    try testing.expectEqual(Range{ .first = 0x41, .last = 0x41 }, try parseCodepointRange("0041"));
    try testing.expectEqual(Range{ .first = 0x41, .last = 0x5A }, try parseCodepointRange("0041..005A"));
}

test "parse scalar sequence parses space-separated codepoints" {
    const seq = try parseScalarSequence(testing.allocator, "0023 FE0F 20E3");
    defer testing.allocator.free(seq);
    try testing.expectEqualSlices(u21, &.{ 0x23, 0xFE0F, 0x20E3 }, seq);
}

test "fields strips comments and trims fields" {
    var parsed = try fields(testing.allocator, "0041..005A ; Lu # [26] letters");
    defer parsed.deinit(testing.allocator);
    try testing.expectEqualStrings("0041..005A", parsed.items[0]);
    try testing.expectEqualStrings("Lu", parsed.items[1]);
}
