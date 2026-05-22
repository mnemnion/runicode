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

    pub fn canonicalProperty(aliases: *const Aliases, name: []const u8) ?[]const u8 {
        return aliases.properties.get(name);
    }

    pub fn canonicalValue(aliases: *const Aliases, property: []const u8, value: []const u8) ?[]const u8 {
        if (aliases.canonicalValueForProperty(property, value)) |canonical| return canonical;

        const canonical_property = aliases.canonicalProperty(property) orelse property;
        if (!std.mem.eql(u8, canonical_property, property)) {
            if (aliases.canonicalValueForProperty(canonical_property, value)) |canonical| return canonical;
        }

        var property_it = aliases.properties.iterator();
        while (property_it.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*, canonical_property)) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, property)) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, canonical_property)) continue;
            if (aliases.canonicalValueForProperty(entry.key_ptr.*, value)) |canonical| return canonical;
        }

        return null;
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
        const canonical = canonicalValueName(property, field_list.items);
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

    fn canonicalValueForProperty(aliases: *const Aliases, property: []const u8, value: []const u8) ?[]const u8 {
        const map = aliases.values.get(property) orelse return null;
        return map.get(value);
    }
};

fn canonicalValueName(property: []const u8, fields: []const []const u8) []const u8 {
    if (fields.len >= 4 and isCanonicalCombiningClass(property)) return fields[3];
    return fields[2];
}

fn isCanonicalCombiningClass(property: []const u8) bool {
    return std.mem.eql(u8, property, "ccc") or
        std.mem.eql(u8, property, "Canonical_Combining_Class");
}

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

test "value aliases resolve after property aliases load later" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try aliases.loadPropertyValueLine("gc ; Lu ; Uppercase_Letter");
    try aliases.loadPropertyLine("gc ; General_Category");

    try testing.expectEqualStrings("Uppercase_Letter", aliases.canonicalValue("gc", "Lu").?);
    try testing.expectEqualStrings("Uppercase_Letter", aliases.canonicalValue("General_Category", "Lu").?);
}

test "value aliases resolve when property aliases load first" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try aliases.loadPropertyLine("gc ; General_Category");
    try aliases.loadPropertyValueLine("gc ; Lu ; Uppercase_Letter");

    try testing.expectEqualStrings("Uppercase_Letter", aliases.canonicalValue("gc", "Lu").?);
    try testing.expectEqualStrings("Uppercase_Letter", aliases.canonicalValue("General_Category", "Lu").?);
}

test "ccc value aliases resolve numeric short and long names to long name" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try aliases.loadPropertyLine("ccc ; Canonical_Combining_Class");
    try aliases.loadPropertyValueLine("ccc ; 0 ; NR ; Not_Reordered");

    try testing.expectEqualStrings("Not_Reordered", aliases.canonicalValue("ccc", "0").?);
    try testing.expectEqualStrings("Not_Reordered", aliases.canonicalValue("ccc", "NR").?);
    try testing.expectEqualStrings("Not_Reordered", aliases.canonicalValue("ccc", "Not_Reordered").?);
    try testing.expectEqualStrings("Not_Reordered", aliases.canonicalValue("Canonical_Combining_Class", "0").?);
}
