const std = @import("std");
const testing = std.testing;
const parse = @import("parse.zig");

pub const Aliases = struct {
    allocator: std.mem.Allocator,
    properties: std.StringHashMapUnmanaged([]const u8) = .empty,
    values: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty,

    pub fn init(allocator: std.mem.Allocator) Aliases {
        return .{ .allocator = allocator };
    }

    pub fn deinit(aliases: *Aliases) void {
        var values_it = aliases.values.iterator();
        while (values_it.next()) |entry| {
            aliases.allocator.free(entry.key_ptr.*);

            var value_it = entry.value_ptr.iterator();
            while (value_it.next()) |value_entry| {
                aliases.allocator.free(value_entry.key_ptr.*);
                aliases.allocator.free(value_entry.value_ptr.*);
            }
            entry.value_ptr.deinit(aliases.allocator);
        }
        aliases.values.deinit(aliases.allocator);

        var property_it = aliases.properties.iterator();
        while (property_it.next()) |entry| {
            aliases.allocator.free(entry.key_ptr.*);
            aliases.allocator.free(entry.value_ptr.*);
        }
        aliases.properties.deinit(aliases.allocator);
    }

    pub fn canonicalProperty(aliases: *Aliases, name: []const u8) ?[]const u8 {
        return aliases.properties.get(name);
    }

    pub fn canonicalValue(aliases: *Aliases, property: []const u8, value: []const u8) ?[]const u8 {
        const canonical_property = aliases.canonicalProperty(property) orelse property;
        const map = aliases.values.get(canonical_property) orelse return null;
        return map.get(value);
    }

    pub fn loadPropertyLine(aliases: *Aliases, line: []const u8) !void {
        var field_list = try parse.fields(aliases.allocator, line);
        defer field_list.deinit(aliases.allocator);

        if (field_list.items.len == 0) return;
        if (field_list.items.len < 2) return error.InvalidPropertyAliasLine;

        const canonical = field_list.items[1];
        for (field_list.items) |alias| {
            try putOwned(&aliases.properties, aliases.allocator, alias, canonical);
        }
    }

    pub fn loadPropertyValueLine(aliases: *Aliases, line: []const u8) !void {
        var field_list = try parse.fields(aliases.allocator, line);
        defer field_list.deinit(aliases.allocator);

        if (field_list.items.len == 0) return;
        if (field_list.items.len < 3) return error.InvalidPropertyValueAliasLine;

        const property = aliases.canonicalProperty(field_list.items[0]) orelse field_list.items[0];
        const map = try aliases.valueMap(property);
        const canonical = field_list.items[2];
        for (field_list.items[1..]) |alias| {
            try putOwned(map, aliases.allocator, alias, canonical);
        }
    }

    pub fn loadPropertyAliasesFile(aliases: *Aliases, io: std.Io, dir: std.Io.Dir) !void {
        var file = try dir.openFile(io, "PropertyAliases.txt", .{});
        defer file.close(io);

        var in_buf: [4096]u8 = undefined;
        var in_reader = file.reader(io, &in_buf);
        while (try in_reader.interface.takeDelimiter('\n')) |line| {
            try aliases.loadPropertyLine(line);
        }
    }

    pub fn loadPropertyValueAliasesFile(aliases: *Aliases, io: std.Io, dir: std.Io.Dir) !void {
        var file = try dir.openFile(io, "PropertyValueAliases.txt", .{});
        defer file.close(io);

        var in_buf: [4096]u8 = undefined;
        var in_reader = file.reader(io, &in_buf);
        while (try in_reader.interface.takeDelimiter('\n')) |line| {
            try aliases.loadPropertyValueLine(line);
        }
    }

    fn valueMap(aliases: *Aliases, property: []const u8) !*std.StringHashMapUnmanaged([]const u8) {
        const owned_property = try aliases.allocator.dupe(u8, property);
        errdefer aliases.allocator.free(owned_property);

        const result = try aliases.values.getOrPut(aliases.allocator, owned_property);
        if (result.found_existing) {
            aliases.allocator.free(owned_property);
        } else {
            result.value_ptr.* = .empty;
        }
        return result.value_ptr;
    }
};

fn putOwned(
    map: *std.StringHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    alias: []const u8,
    canonical: []const u8,
) !void {
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);

    const owned_canonical = try allocator.dupe(u8, canonical);
    errdefer allocator.free(owned_canonical);

    const result = try map.getOrPut(allocator, owned_alias);
    if (result.found_existing) {
        allocator.free(owned_alias);
        allocator.free(result.value_ptr.*);
    }
    result.value_ptr.* = owned_canonical;
}

test "value aliases resolve canonical names and aliases" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try aliases.loadPropertyValueLine("gc ; Lu ; Uppercase_Letter");
    try aliases.loadPropertyValueLine("gc ; Nd ; Decimal_Number ; digit");

    try testing.expectEqualStrings("Uppercase_Letter", aliases.canonicalValue("gc", "Lu").?);
    try testing.expectEqualStrings("Decimal_Number", aliases.canonicalValue("gc", "digit").?);
}

test "property aliases resolve short names" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try aliases.loadPropertyLine("gc ; General_Category");
    try aliases.loadPropertyLine("sc ; Script");

    try testing.expectEqualStrings("General_Category", aliases.canonicalProperty("gc").?);
    try testing.expectEqualStrings("Script", aliases.canonicalProperty("sc").?);
}
