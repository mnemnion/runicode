const std = @import("std");
const testing = std.testing;
const parse = @import("parse.zig");

pub const PropertyValue = struct {
    ranges: std.ArrayList(parse.Range) = .empty,
    codepoints: std.ArrayList(u21) = .empty,
    utf8: std.ArrayList(u8) = .empty,

    pub fn deinit(value: *PropertyValue, allocator: std.mem.Allocator) void {
        value.ranges.deinit(allocator);
        value.codepoints.deinit(allocator);
        value.utf8.deinit(allocator);
    }
};

pub const PropertyGroup = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMapUnmanaged(PropertyValue) = .empty,

    pub fn init(allocator: std.mem.Allocator) PropertyGroup {
        return .{ .allocator = allocator };
    }

    pub fn deinit(group: *PropertyGroup) void {
        var it = group.values.iterator();
        while (it.next()) |entry| {
            group.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(group.allocator);
        }
        group.values.deinit(group.allocator);
    }

    pub fn value(group: *PropertyGroup, name: []const u8) ?*PropertyValue {
        return group.values.getPtr(name);
    }

    fn getOrPutValue(group: *PropertyGroup, name: []const u8) !*PropertyValue {
        const owned_name = try group.allocator.dupe(u8, name);
        errdefer group.allocator.free(owned_name);

        const result = try group.values.getOrPut(group.allocator, owned_name);
        if (result.found_existing) {
            group.allocator.free(owned_name);
        } else {
            result.value_ptr.* = .{};
        }
        return result.value_ptr;
    }
};

pub const Db = struct {
    allocator: std.mem.Allocator,
    groups: std.StringHashMapUnmanaged(PropertyGroup) = .empty,

    pub fn init(allocator: std.mem.Allocator) Db {
        return .{ .allocator = allocator };
    }

    pub fn deinit(db: *Db) void {
        var it = db.groups.iterator();
        while (it.next()) |entry| {
            db.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        db.groups.deinit(db.allocator);
    }

    pub fn property(db: *Db, name: []const u8) ?*PropertyGroup {
        return db.groups.getPtr(name);
    }

    pub fn propertyCount(db: *const Db) usize {
        return db.groups.count();
    }

    pub fn addRange(db: *Db, property_name: []const u8, value_name: []const u8, range: parse.Range) !void {
        const group = try db.getOrPutProperty(property_name);
        const prop_value = try group.getOrPutValue(value_name);
        try prop_value.ranges.append(db.allocator, range);

        var codepoint = range.first;
        while (codepoint <= range.last) : (codepoint += 1) {
            try prop_value.codepoints.append(db.allocator, codepoint);

            var buf: [4]u8 = undefined;
            const len = try wtf8Encode(codepoint, &buf);
            try prop_value.utf8.appendSlice(db.allocator, buf[0..len]);
        }
    }

    fn getOrPutProperty(db: *Db, name: []const u8) !*PropertyGroup {
        const owned_name = try db.allocator.dupe(u8, name);
        errdefer db.allocator.free(owned_name);

        const result = try db.groups.getOrPut(db.allocator, owned_name);
        if (result.found_existing) {
            db.allocator.free(owned_name);
        } else {
            result.value_ptr.* = PropertyGroup.init(db.allocator);
        }
        return result.value_ptr;
    }
};

fn wtf8Encode(codepoint: u21, buf: []u8) !usize {
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
        if (buf.len < 3) return error.NoSpaceLeft;
        buf[0] = 0xE0 | @as(u8, @intCast(codepoint >> 12));
        buf[1] = 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3F));
        buf[2] = 0x80 | @as(u8, @intCast(codepoint & 0x3F));
        return 3;
    }
    const len = std.unicode.utf8Encode(codepoint, buf) catch |err| switch (err) {
        error.Utf8CannotEncodeSurrogateHalf => unreachable,
        error.CodepointTooLarge => return err,
    };
    return @intCast(len);
}

test "property group accumulates range as codepoints and utf8" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x43 });

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Lu").?;
    try testing.expectEqualSlices(u21, &.{ 0x41, 0x42, 0x43 }, value.codepoints.items);
    try testing.expectEqualStrings("ABC", value.utf8.items);
}

test "surrogate codepoints encode as WTF-8 bytes" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Cs", .{ .first = 0xD800, .last = 0xD800 });

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Cs").?;
    try testing.expectEqualSlices(u21, &.{0xD800}, value.codepoints.items);
    try testing.expectEqualSlices(u8, &.{ 0xED, 0xA0, 0x80 }, value.utf8.items);
}
