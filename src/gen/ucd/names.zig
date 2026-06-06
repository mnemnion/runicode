const std = @import("std");
const testing = std.testing;

const fysti = @import("fysti");
const parse = @import("parse.zig");
const ucd_tools = @import("../ucd-tools.zig");

pub fn emitCharacterNames(
    allocator: std.mem.Allocator,
    io: std.Io,
    ucd_dir: std.Io.Dir,
    out_dir: std.Io.Dir,
) !void {
    var names = CharacterNameMap.init(allocator);
    defer names.deinit();

    try names.loadDerivedNameFile(io, ucd_dir);
    try names.loadNameAliasesFile(io, ucd_dir);

    var fst_bytes = try names.buildFst(allocator);
    defer fst_bytes.deinit();

    try writeCharacterNamesFile(io, out_dir, fst_bytes.written());
}

const CharacterNameMap = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(u21) = .empty,

    fn init(allocator: std.mem.Allocator) CharacterNameMap {
        return .{ .allocator = allocator };
    }

    fn deinit(names: *CharacterNameMap) void {
        var it = names.map.keyIterator();
        while (it.next()) |key| names.allocator.free(key.*);
        names.map.deinit(names.allocator);
    }

    fn loadDerivedNameFile(names: *CharacterNameMap, io: std.Io, ucd_dir: std.Io.Dir) !void {
        var file = try ucd_dir.openFile(io, "extracted/DerivedName.txt", .{});
        defer file.close(io);

        var in_buf: [4096]u8 = undefined;
        var in_reader = file.reader(io, &in_buf);
        while (try in_reader.interface.takeDelimiter('\n')) |line| {
            var field_storage: [2][]const u8 = undefined;
            const fields = parse.fieldsBounded(line, &field_storage) catch |err| switch (err) {
                error.TooManyFields => return error.InvalidDerivedNameLine,
            };

            if (fields.len == 0) continue;
            if (fields.len != 2) return error.InvalidDerivedNameLine;

            const range = try parse.parseCodepointRange(fields[0]);
            var codepoint = range.first;
            while (codepoint <= range.last) : (codepoint += 1) {
                try names.putPatternName(fields[1], codepoint);
            }
        }
    }

    fn loadNameAliasesFile(names: *CharacterNameMap, io: std.Io, ucd_dir: std.Io.Dir) !void {
        var file = try ucd_dir.openFile(io, "NameAliases.txt", .{});
        defer file.close(io);

        var in_buf: [4096]u8 = undefined;
        var in_reader = file.reader(io, &in_buf);
        while (try in_reader.interface.takeDelimiter('\n')) |line| {
            var field_storage: [3][]const u8 = undefined;
            const fields = parse.fieldsBounded(line, &field_storage) catch |err| switch (err) {
                error.TooManyFields => return error.InvalidNameAliasLine,
            };

            if (fields.len == 0) continue;
            if (fields.len != 3) return error.InvalidNameAliasLine;

            try names.putName(fields[1], try parse.parseCodepoint(fields[0]));
        }
    }

    fn putPatternName(names: *CharacterNameMap, pattern: []const u8, codepoint: u21) !void {
        const star = std.mem.indexOfScalar(u8, pattern, '*') orelse {
            return names.putName(pattern, codepoint);
        };

        var name_buf: [128]u8 = undefined;
        const hex = try std.fmt.bufPrint(name_buf[star..], "{X:0>4}", .{codepoint});
        const name_len = star + hex.len + pattern.len - star - 1;
        if (name_len > name_buf.len) return error.CharacterNameTooLong;

        @memcpy(name_buf[0..star], pattern[0..star]);
        @memcpy(name_buf[star + hex.len .. name_len], pattern[star + 1 ..]);

        try names.putName(name_buf[0..name_len], codepoint);
    }

    fn putName(names: *CharacterNameMap, name: []const u8, codepoint: u21) !void {
        var key_buf: [128]u8 = undefined;
        const key_len = ucd_tools.normalizeCharacterName(name, &key_buf) orelse return error.InvalidCharacterName;
        const key = key_buf[0..key_len];

        const owned_key = try names.allocator.dupe(u8, key);
        errdefer names.allocator.free(owned_key);

        const result = try names.map.getOrPut(names.allocator, owned_key);
        if (result.found_existing) {
            names.allocator.free(owned_key);
            if (result.value_ptr.* != codepoint) return error.DuplicateCharacterName;
            return;
        }
        result.value_ptr.* = codepoint;
    }

    fn buildFst(names: *CharacterNameMap, allocator: std.mem.Allocator) !std.Io.Writer.Allocating {
        const keys = try names.sortedKeys(allocator);
        defer allocator.free(keys);

        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();

        var builder = try fysti.MapBuilder.init(
            allocator,
            &out.writer,
            .unspecified,
            .{ .bucket_count = 100_000, .entries_per_bucket = 2 },
        );
        defer builder.deinit(allocator);

        for (keys) |key| {
            try builder.insert(allocator, key, names.map.get(key).?);
        }
        try builder.finish(allocator);
        return out;
    }

    fn sortedKeys(names: *CharacterNameMap, allocator: std.mem.Allocator) ![][]const u8 {
        const keys = try allocator.alloc([]const u8, names.map.count());
        var it = names.map.keyIterator();
        var idx: usize = 0;
        while (it.next()) |key| : (idx += 1) keys[idx] = key.*;
        std.mem.sort([]const u8, keys, {}, ltString);
        return keys;
    }
};

fn writeCharacterNamesFile(io: std.Io, out_dir: std.Io.Dir, fst_bytes: []const u8) !void {
    var file = try out_dir.createFile(io, "names.zig", .{ .lock = .exclusive });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    const writer = &file_writer.interface;

    try writer.writeAll(header_txt);
    try writer.writeAll(
        \\const fysti = @import("fysti");
        \\const ucd_tools = @import("ucd-tools");
        \\
        \\pub const CharacterNames = struct {
        \\    map: fysti.Map = fysti.Map.init(data),
        \\    buf: [128]u8 = undefined,
        \\
        \\    pub fn get(names: *CharacterNames, name: []const u8) ?u21 {
        \\        const len = ucd_tools.normalizeCharacterName(name, &names.buf) orelse return null;
        \\        const value = names.map.get(names.buf[0..len]) orelse return null;
        \\        return @intCast(value);
        \\    }
        \\};
        \\
        \\pub fn codepoint(name: []const u8) ?u21 {
        \\    var names = CharacterNames{};
        \\    return names.get(name);
        \\}
        \\
        \\const data: []const u8 = &.{
        \\
    );
    for (fst_bytes, 0..) |byte, idx| {
        if (idx % 16 == 0) try writer.writeAll("    ");
        try writer.print("0x{X:0>2}, ", .{byte});
        if (idx % 16 == 15) try writer.writeByte('\n');
    }
    if (fst_bytes.len % 16 != 0) try writer.writeByte('\n');
    try writer.writeAll("};\n");
    try writer.flush();
}

fn ltString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

test "character name map includes aliases and derived name patterns" {
    var names = CharacterNameMap.init(testing.allocator);
    defer names.deinit();

    try names.putPatternName("CJK UNIFIED IDEOGRAPH-*", 0x4E00);
    try names.putName("LINE FEED", 0x000A);

    var fst_bytes = try names.buildFst(testing.allocator);
    defer fst_bytes.deinit();

    const map = fysti.Map.init(fst_bytes.written());
    try map.verify();
    try testing.expectEqual(@as(?u64, 0x4E00), map.get("cjkunifiedideograph-4e00"));
    try testing.expectEqual(@as(?u64, 0x000A), map.get("linefeed"));
}

const header_txt =
    \\//! Generated source!
    \\//! Do not modify!
    \\
    \\
;
