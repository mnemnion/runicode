const std = @import("std");
const testing = std.testing;

/// Inclusive Unicode scalar range parsed from UCD text.
pub const Range = struct {
    first: u21,
    last: u21,
};

/// Borrowed semicolon-separated UCD fields from a source line.
pub const FieldList = struct {
    items: []const []const u8,

    /// Frees the field slice owned by this list.
    pub fn deinit(list: FieldList, allocator: std.mem.Allocator) void {
        allocator.free(list.items);
    }
};

/// Parses one hexadecimal Unicode scalar value.
pub fn parseCodepoint(text: []const u8) !u21 {
    return std.fmt.parseInt(u21, text, 16);
}

/// Parses either one scalar or an inclusive `first..last` scalar range.
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

/// Parses a space-separated sequence of hexadecimal Unicode scalar values.
pub fn parseScalarSequence(allocator: std.mem.Allocator, text: []const u8) ![]u21 {
    var list: std.ArrayList(u21) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |part| {
        try list.append(allocator, try parseCodepoint(part));
    }
    return try list.toOwnedSlice(allocator);
}

/// Strips comments from a UCD line and returns trimmed semicolon-separated fields.
pub fn fields(allocator: std.mem.Allocator, line: []const u8) !FieldList {
    const uncommented = if (std.mem.indexOfScalar(u8, line, '#')) |hash| line[0..hash] else line;
    const trimmed = std.mem.trim(u8, uncommented, " \t\r\n");
    if (trimmed.len == 0) return .{ .items = &.{} };

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

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

test "fields returns no fields for comment-only line" {
    var parsed = try fields(testing.allocator, "# comment");
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), parsed.items.len);
}

test "fields returns no fields for blank line" {
    var parsed = try fields(testing.allocator, "   ");
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), parsed.items.len);
}
