const std = @import("std");
const testing = std.testing;

const Aliases = @import("aliases.zig").Aliases;
const Db = @import("db.zig").Db;
const Range = @import("parse.zig").Range;
const RuneSet = @import("runeset").RuneSet;

pub const OutputDir = struct {
    io: std.Io,
    dir: std.Io.Dir,
    runicode_path: []const u8 = "runicode.zig",
    sets_path: []const u8 = "sets.zig",
    codepoints_path: []const u8 = "codepoints.zig",
    strs_path: []const u8 = "strs.zig",
    enums_path: []const u8 = "enums.zig",
    maps_path: []const u8 = "maps.zig",
};

pub fn emitRoots(allocator: std.mem.Allocator, dir: OutputDir, db: *Db, aliases: *const Aliases) !void {
    const group_names = try sortedGroupNames(allocator, db);
    defer allocator.free(group_names);

    try writeDataFiles(allocator, dir, group_names, db, aliases);
    try writeRootFile(dir, dir.enums_path, writeEnumsRoot, .{ group_names, db });
    try writeMapsFiles(allocator, dir, group_names, db);
    try writeRootFile(dir, dir.runicode_path, writeRunicodeRoot, .{});
}

fn writeDataFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: *Db,
    aliases: *const Aliases,
) !void {
    try writeSetsFiles(allocator, dir, group_names, db, aliases);
    try writeCodepointsFiles(allocator, dir, group_names, db, aliases);
    try writeStrsFiles(allocator, dir, group_names, db, aliases);
}

fn writeRootFile(
    dir: OutputDir,
    path: []const u8,
    comptime writeRoot: anytype,
    args: anytype,
) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    try @call(.auto, writeRoot, .{&file_writer.interface} ++ args);
    try file_writer.interface.flush();
}

fn writeStrsFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: *Db,
    aliases: *const Aliases,
) !void {
    try dir.dir.createDirPath(dir.io, "strs");

    var root_file = try dir.dir.createFile(dir.io, dir.strs_path, .{ .lock = .exclusive });
    defer root_file.close(dir.io);
    var root_buf: [4096]u8 = undefined;
    var root_writer = root_file.writer(dir.io, &root_buf);
    const writer = &root_writer.interface;

    try writer.writeAll(header_txt);
    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        const group_dir = try semanticGroupDir(allocator, "strs", group_name);
        defer allocator.free(group_dir);
        try dir.dir.createDirPath(dir.io, group_dir);

        const group_path = try semanticGroupFilePath(allocator, "strs", group_name);
        defer allocator.free(group_path);
        try writer.print("pub const {f} = @import(\"{s}\");\n", .{ identifier(group_name), group_path });

        var group_file = try dir.dir.createFile(dir.io, group_path, .{ .lock = .exclusive });
        defer group_file.close(dir.io);
        var group_buf: [4096]u8 = undefined;
        var group_writer = group_file.writer(dir.io, &group_buf);
        const group_out = &group_writer.interface;
        try group_out.writeAll(header_txt);

        for (value_names) |value_name| {
            const value = group.value(value_name).?;
            const decl_name = try declName(allocator, value_name);
            defer allocator.free(decl_name);
            const value_path = try semanticValuePath(allocator, "strs", group_name, value_name);
            defer allocator.free(value_path);
            const import_path = try relativeGroupImportPath(allocator, group_path, value_path);
            defer allocator.free(import_path);
            try writeStrsValueFile(allocator, dir, value_path, decl_name, value.ranges.items);
            try group_out.print("pub const {f} = @import(\"{s}\").{f};\n", .{ identifier(decl_name), import_path, identifier(decl_name) });
        }
        try writeGroupValueAliases(allocator, group_out, group_name, value_names, aliases);
        try group_out.flush();
    }
    try writer.flush();
}

fn writeStrsValueFile(allocator: std.mem.Allocator, dir: OutputDir, path: []const u8, decl_name: []const u8, ranges: []const Range) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    const rune_set = try createRuneSetFromRanges(ranges, allocator);
    defer rune_set.deinit(allocator);

    try writer.writeAll(header_txt);
    try writer.print("pub const {f} = ", .{identifier(decl_name)});
    try writeStringLiteral(writer, rune_set);
    try writer.writeAll(";\n");
    try writer.flush();
}

fn writeCodepointsFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: *Db,
    aliases: *const Aliases,
) !void {
    try dir.dir.createDirPath(dir.io, "codepoints");

    var root_file = try dir.dir.createFile(dir.io, dir.codepoints_path, .{ .lock = .exclusive });
    defer root_file.close(dir.io);
    var root_buf: [4096]u8 = undefined;
    var root_writer = root_file.writer(dir.io, &root_buf);
    const writer = &root_writer.interface;

    try writer.writeAll(header_txt);
    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        const group_dir = try semanticGroupDir(allocator, "codepoints", group_name);
        defer allocator.free(group_dir);
        try dir.dir.createDirPath(dir.io, group_dir);

        const group_path = try semanticGroupFilePath(allocator, "codepoints", group_name);
        defer allocator.free(group_path);
        try writer.print("pub const {f} = @import(\"{s}\");\n", .{ identifier(group_name), group_path });

        var group_file = try dir.dir.createFile(dir.io, group_path, .{ .lock = .exclusive });
        defer group_file.close(dir.io);
        var group_buf: [4096]u8 = undefined;
        var group_writer = group_file.writer(dir.io, &group_buf);
        const group_out = &group_writer.interface;
        try group_out.writeAll(header_txt);

        for (value_names) |value_name| {
            const value = group.value(value_name).?;
            const decl_name = try declName(allocator, value_name);
            defer allocator.free(decl_name);
            const value_path = try semanticValuePath(allocator, "codepoints", group_name, value_name);
            defer allocator.free(value_path);
            const import_path = try relativeGroupImportPath(allocator, group_path, value_path);
            defer allocator.free(import_path);
            try writeCodepointsValueFile(allocator, dir, value_path, decl_name, value.ranges.items);
            try group_out.print("pub const {f} = @import(\"{s}\").{f};\n", .{ identifier(decl_name), import_path, identifier(decl_name) });
        }
        try writeGroupValueAliases(allocator, group_out, group_name, value_names, aliases);
        try group_out.flush();
    }
    try writer.flush();
}

fn writeCodepointsValueFile(allocator: std.mem.Allocator, dir: OutputDir, path: []const u8, decl_name: []const u8, ranges: []const Range) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    const rune_set = try createRuneSetFromRanges(ranges, allocator);
    defer rune_set.deinit(allocator);

    try writer.writeAll(header_txt);
    try writer.print("pub const {f}: [{d}]u21 = .{{ ", .{ identifier(decl_name), rune_set.runeCount() });
    try writeCodepoints(writer, rune_set);
    try writer.writeAll("};\n");
    try writer.flush();
}

fn writeSetsFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: *Db,
    aliases: *const Aliases,
) !void {
    try dir.dir.createDirPath(dir.io, "sets");

    var root_file = try dir.dir.createFile(dir.io, dir.sets_path, .{ .lock = .exclusive });
    defer root_file.close(dir.io);
    var root_buf: [4096]u8 = undefined;
    var root_writer = root_file.writer(dir.io, &root_buf);
    const writer = &root_writer.interface;

    try writer.writeAll(header_txt);
    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        const group_dir = try semanticGroupDir(allocator, "sets", group_name);
        defer allocator.free(group_dir);
        try dir.dir.createDirPath(dir.io, group_dir);

        const group_path = try semanticGroupFilePath(allocator, "sets", group_name);
        defer allocator.free(group_path);
        try writer.print("pub const {f} = @import(\"{s}\");\n", .{ identifier(group_name), group_path });

        var group_file = try dir.dir.createFile(dir.io, group_path, .{ .lock = .exclusive });
        defer group_file.close(dir.io);
        var group_buf: [4096]u8 = undefined;
        var group_writer = group_file.writer(dir.io, &group_buf);
        const group_out = &group_writer.interface;
        try group_out.writeAll(header_txt);

        for (value_names) |value_name| {
            const value = group.value(value_name).?;
            const decl_name = try declName(allocator, value_name);
            defer allocator.free(decl_name);
            const value_path = try semanticValuePath(allocator, "sets", group_name, value_name);
            defer allocator.free(value_path);
            const import_path = try relativeGroupImportPath(allocator, group_path, value_path);
            defer allocator.free(import_path);
            try writeSetsValueFile(allocator, dir, value_path, decl_name, value.ranges.items);
            try group_out.print("pub const {f} = @import(\"{s}\").{f};\n", .{ identifier(decl_name), import_path, identifier(decl_name) });
        }
        try writeGroupValueAliases(allocator, group_out, group_name, value_names, aliases);
        try group_out.flush();
    }
    try writer.flush();
}

fn writeSetsValueFile(allocator: std.mem.Allocator, dir: OutputDir, path: []const u8, decl_name: []const u8, ranges: []const Range) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    const rune_set = try createRuneSetFromRanges(ranges, allocator);
    defer rune_set.deinit(allocator);

    try writer.writeAll(header_txt);
    try writer.writeAll("const RuneSet = @import(\"runeset\").RuneSet;\n\n");
    try writer.print("/// Length: {d} words.\n", .{rune_set.body.len});
    try rune_set.serialize(writer, .public, decl_name);
    try writer.flush();
}

fn writeGroupValueAliases(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    group_name: []const u8,
    value_names: []const []const u8,
    aliases: *const Aliases,
) !void {
    const alias_property = valueAliasProperty(group_name) orelse return;

    var seen_decls: std.StringHashMapUnmanaged(void) = .empty;
    defer freeSeenMatches(allocator, &seen_decls);

    for (value_names) |value_name| {
        const value_decl = try declName(allocator, value_name);
        errdefer allocator.free(value_decl);
        const result = try seen_decls.getOrPut(allocator, value_decl);
        if (result.found_existing) allocator.free(value_decl);
    }

    for (value_names) |value_name| {
        const target_decl = try declName(allocator, value_name);
        defer allocator.free(target_decl);
        const canonical_value = aliases.canonicalValue(alias_property, value_name) orelse
            aliases.canonicalValue(alias_property, target_decl) orelse
            value_name;
        const value_aliases = try aliases.valueAliases(allocator, alias_property, canonical_value);
        defer allocator.free(value_aliases);

        for (value_aliases) |alias| {
            const alias_decl = try declName(allocator, alias);
            errdefer allocator.free(alias_decl);
            if (std.mem.eql(u8, alias_decl, target_decl)) {
                allocator.free(alias_decl);
                continue;
            }

            const result = try seen_decls.getOrPut(allocator, alias_decl);
            if (result.found_existing) {
                allocator.free(alias_decl);
                continue;
            }
            try writer.print("pub const {f} = {f};\n", .{ identifier(alias_decl), identifier(target_decl) });
        }
    }
}

fn writeEnumsRoot(writer: *std.Io.Writer, group_names: []const []const u8, db: *Db) !void {
    try writer.writeAll(header_txt);
    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        try writer.print("pub const {f} = enum {{\n", .{identifier(group_name)});
        for (value_names) |value_name| {
            const decl_name = try declName(group.allocator, value_name);
            defer group.allocator.free(decl_name);
            try writer.print("    {f},\n", .{identifier(decl_name)});
        }
        try writer.writeAll("};\n\n");
    }
}

fn writeRunicodeRoot(writer: *std.Io.Writer) !void {
    try writer.writeAll(header_txt);
    try writer.writeAll(
        \\/// Unicode property data as RuneSet values.
        \\pub const sets = @import("sets.zig");
        \\
        \\/// Unicode property data as sorted codepoint slices.
        \\pub const codepoints = @import("codepoints.zig");
        \\
        \\/// Unicode property data as UTF-8 strings.
        \\pub const strs = @import("strs.zig");
        \\
        \\/// Unicode property enum types.
        \\pub const enums = @import("enums.zig");
        \\
        \\/// Loose-matching maps for Unicode property namespaces.
        \\pub const maps = @import("maps.zig");
        \\
        \\/// Compile-time constructor for loose-matching property maps.
        \\pub const NamedMap = @import("ucd-tools").NamedMap;
        \\
    );
}

fn writeMapsFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: *Db,
) !void {
    try dir.dir.createDirPath(dir.io, "maps");

    var root_file = try dir.dir.createFile(dir.io, dir.maps_path, .{ .lock = .exclusive });
    defer root_file.close(dir.io);
    var root_buf: [4096]u8 = undefined;
    var root_writer = root_file.writer(dir.io, &root_buf);
    const writer = &root_writer.interface;

    try writer.writeAll(header_txt);

    for (group_names) |group_name| {
        if (!isMappedGroup(group_name)) continue;

        _ = db.property(group_name).?;

        const group_path = try semanticGroupFilePath(allocator, "maps", group_name);
        defer allocator.free(group_path);
        try createParentDirPath(dir, group_path);
        try writeMapGroupFile(allocator, dir, group_path, group_name);
        try writer.print("pub const {f} = @import(\"{s}\");\n", .{ identifier(group_name), group_path });
    }
    try writer.flush();
}

fn writeMapGroupFile(allocator: std.mem.Allocator, dir: OutputDir, path: []const u8, group_name: []const u8) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    const sets_target = try semanticGroupFilePath(allocator, "sets", group_name);
    defer allocator.free(sets_target);
    const sets_path = try relativeImportPath(allocator, path, sets_target);
    defer allocator.free(sets_path);
    const codepoints_target = try semanticGroupFilePath(allocator, "codepoints", group_name);
    defer allocator.free(codepoints_target);
    const codepoints_path = try relativeImportPath(allocator, path, codepoints_target);
    defer allocator.free(codepoints_path);
    const strs_target = try semanticGroupFilePath(allocator, "strs", group_name);
    defer allocator.free(strs_target);
    const strs_path = try relativeImportPath(allocator, path, strs_target);
    defer allocator.free(strs_path);
    const enums_path = try relativeImportPath(allocator, path, "enums.zig");
    defer allocator.free(enums_path);

    try writer.writeAll(header_txt);
    try writer.print(
        \\const ucd_tools = @import("ucd-tools");
        \\const sets = @import("{s}");
        \\const codepoints = @import("{s}");
        \\const strs = @import("{s}");
        \\const enums = @import("{s}");
        \\
        \\
        \\
    , .{ sets_path, codepoints_path, strs_path, enums_path });
    try writer.print(
        \\pub const Sets = ucd_tools.NamedMap(sets);
        \\pub const Codepoints = ucd_tools.NamedMap(codepoints);
        \\pub const Strs = ucd_tools.NamedMap(strs);
        \\pub const Enum = enums.{f};
        \\
    , .{
        identifier(group_name),
    });
    try writer.flush();
}

fn relativeImportPath(allocator: std.mem.Allocator, from_path: []const u8, target_path: []const u8) ![]const u8 {
    const from_dir = std.fs.path.dirname(from_path) orelse "";
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var components = std.mem.tokenizeScalar(u8, from_dir, '/');
    while (components.next()) |_| try result.appendSlice(allocator, "../");
    try result.appendSlice(allocator, target_path);
    return try result.toOwnedSlice(allocator);
}

fn freeSeenMatches(allocator: std.mem.Allocator, seen_matches: *std.StringHashMapUnmanaged(void)) void {
    var it = seen_matches.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    seen_matches.deinit(allocator);
}

fn createRuneSetFromRanges(ranges: []const Range, allocator: std.mem.Allocator) !RuneSet {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    for (ranges) |range| {
        var codepoint = range.first;
        while (codepoint <= range.last) : (codepoint += 1) {
            var buf: [4]u8 = undefined;
            const len = try wtf8Encode(codepoint, &buf);
            try bytes.appendSlice(allocator, buf[0..len]);
        }
    }

    return try RuneSet.createFromConstString(bytes.items, allocator);
}

fn writeCodepoints(writer: *std.Io.Writer, rune_set: RuneSet) !void {
    var iter = rune_set.iterateRunes();
    while (iter.next()) |rune| {
        const codepoint = (try wtf8Decode(rune)).codepoint;
        try writer.print("0x{X}, ", .{codepoint});
    }
}

fn writeStringLiteral(writer: *std.Io.Writer, rune_set: RuneSet) !void {
    try writer.writeByte('"');
    var iter = rune_set.iterateRunes();
    while (iter.next()) |rune| {
        const codepoint = (try wtf8Decode(rune)).codepoint;
        try writeStringLiteralCodepoint(writer, codepoint);
    }
    try writer.writeByte('"');
}

const DecodedWtf8 = struct {
    codepoint: u21,
    len: usize,
};

fn wtf8Decode(bytes: []const u8) !DecodedWtf8 {
    if (bytes.len == 0) return error.InvalidWtf8;
    const first = bytes[0];
    if (first <= 0x7F) return .{ .codepoint = first, .len = 1 };
    if (first >= 0xC0 and first <= 0xDF) {
        if (bytes.len < 2 or !isFollowByte(bytes[1])) return error.InvalidWtf8;
        return .{
            .codepoint = (@as(u21, first & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F),
            .len = 2,
        };
    }
    if (first >= 0xE0 and first <= 0xEF) {
        if (bytes.len < 3 or !isFollowByte(bytes[1]) or !isFollowByte(bytes[2])) return error.InvalidWtf8;
        return .{
            .codepoint = (@as(u21, first & 0x0F) << 12) |
                (@as(u21, bytes[1] & 0x3F) << 6) |
                @as(u21, bytes[2] & 0x3F),
            .len = 3,
        };
    }
    if (first >= 0xF0 and first <= 0xF7) {
        if (bytes.len < 4 or !isFollowByte(bytes[1]) or !isFollowByte(bytes[2]) or !isFollowByte(bytes[3])) return error.InvalidWtf8;
        return .{
            .codepoint = (@as(u21, first & 0x07) << 18) |
                (@as(u21, bytes[1] & 0x3F) << 12) |
                (@as(u21, bytes[2] & 0x3F) << 6) |
                @as(u21, bytes[3] & 0x3F),
            .len = 4,
        };
    }
    return error.InvalidWtf8;
}

fn isFollowByte(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xBF;
}

fn writeStringLiteralCodepoint(writer: *std.Io.Writer, codepoint: u21) !void {
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
        var buf: [3]u8 = undefined;
        const len = try wtf8Encode(codepoint, &buf);
        for (buf[0..len]) |byte| try writer.print("\\x{X:0>2}", .{byte});
        return;
    }

    switch (codepoint) {
        '\n' => return writer.writeAll("\\n"),
        '\r' => return writer.writeAll("\\r"),
        '\t' => return writer.writeAll("\\t"),
        '"' => return writer.writeAll("\\\""),
        '\\' => return writer.writeAll("\\\\"),
        0x20...0x21, 0x23...0x5B, 0x5D...0x7E => return writer.writeByte(@intCast(codepoint)),
        0...8, 11...12, 14...0x1F, 0x7F => return writer.print("\\x{X:0>2}", .{codepoint}),
        else => {
            var buf: [4]u8 = undefined;
            const len = try wtf8Encode(codepoint, &buf);
            try writer.writeAll(buf[0..len]);
        },
    }
}

fn semanticValuePath(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    group_name: []const u8,
    value_name: []const u8,
) ![]const u8 {
    const group_dir = try semanticGroupDir(allocator, prefix, group_name);
    defer allocator.free(group_dir);
    const file_name = try pathName(allocator, value_name);
    defer allocator.free(file_name);
    return try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ group_dir, file_name });
}

fn semanticGroupFilePath(allocator: std.mem.Allocator, prefix: []const u8, group_name: []const u8) ![]const u8 {
    const group_dir = try semanticGroupDir(allocator, prefix, group_name);
    defer allocator.free(group_dir);
    return try std.fmt.allocPrint(allocator, "{s}.zig", .{group_dir});
}

fn createParentDirPath(dir: OutputDir, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try dir.dir.createDirPath(dir.io, parent);
}

fn relativeGroupImportPath(
    allocator: std.mem.Allocator,
    group_path: []const u8,
    value_path: []const u8,
) ![]const u8 {
    const group_dir = std.fs.path.dirname(group_path) orelse "";
    if (group_dir.len == 0) return try allocator.dupe(u8, value_path);

    const prefix_len = group_dir.len + 1;
    if (!std.mem.startsWith(u8, value_path, group_dir) or
        value_path.len <= prefix_len or
        value_path[group_dir.len] != '/')
    {
        return error.InvalidGeneratedPath;
    }
    return try allocator.dupe(u8, value_path[prefix_len..]);
}

fn declName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return pathName(allocator, name);
}

fn semanticGroupDir(allocator: std.mem.Allocator, prefix: []const u8, group_name: []const u8) ![]const u8 {
    const suffix = semanticGroupSuffix(group_name);
    if (suffix) |literal| {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, literal });
    }

    const group_path = try pathName(allocator, group_name);
    defer allocator.free(group_path);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, group_path });
}

fn semanticGroupSuffix(group_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, group_name, "Blocks")) return "blocks";
    if (std.mem.eql(u8, group_name, "CoreProperties")) return "props";
    if (std.mem.eql(u8, group_name, "GeneralCategory")) return "gencat";
    if (std.mem.eql(u8, group_name, "Scripts")) return "scripts";
    if (std.mem.eql(u8, group_name, "ScriptsExtended")) return "scripts_ext";
    if (std.mem.eql(u8, group_name, "GraphemeBreak")) return "aux-props/GraphemeBreak";
    if (std.mem.eql(u8, group_name, "SentenceBreak")) return "aux-props/SentenceBreak";
    if (std.mem.eql(u8, group_name, "WordBreak")) return "aux-props/WordBreak";
    return null;
}

fn valueAliasProperty(group_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, group_name, "Blocks")) return "blk";
    if (std.mem.eql(u8, group_name, "GeneralCategory")) return "gc";
    if (std.mem.eql(u8, group_name, "GraphemeBreak")) return "GCB";
    if (std.mem.eql(u8, group_name, "Scripts")) return "sc";
    if (std.mem.eql(u8, group_name, "ScriptsExtended")) return "sc";
    if (std.mem.eql(u8, group_name, "SentenceBreak")) return "SB";
    if (std.mem.eql(u8, group_name, "WordBreak")) return "WB";
    return null;
}

fn pathName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var pending_sep = false;
    for (name) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9' => {
                if (pending_sep and result.items.len != 0 and result.items[result.items.len - 1] != '_') {
                    try result.append(allocator, '_');
                }
                try result.append(allocator, byte);
                pending_sep = false;
            },
            '_', ' ', '-' => {
                pending_sep = result.items.len != 0;
            },
            else => {
                if (result.items.len != 0 and result.items[result.items.len - 1] != '_') {
                    try result.append(allocator, '_');
                }
                var buf: [2]u8 = undefined;
                const hex = try std.fmt.bufPrint(&buf, "{X:0>2}", .{byte});
                try result.appendSlice(allocator, hex);
                pending_sep = true;
            },
        }
    }

    if (result.items.len == 0) try result.append(allocator, '_');
    return try result.toOwnedSlice(allocator);
}

fn sortedGroupNames(allocator: std.mem.Allocator, db: *Db) ![][]const u8 {
    var names = try allocator.alloc([]const u8, db.groups.count());
    var it = db.groups.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) names[idx] = entry.key_ptr.*;
    std.mem.sort([]const u8, names, {}, ltString);
    return names;
}

fn sortedValueNames(allocator: std.mem.Allocator, group: anytype) ![][]const u8 {
    var names = try allocator.alloc([]const u8, group.values.count());
    var it = group.values.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) names[idx] = entry.key_ptr.*;
    std.mem.sort([]const u8, names, {}, ltString);
    return names;
}

fn ltString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn isMappedGroup(name: []const u8) bool {
    inline for (mapped_groups) |mapped_group| {
        if (std.mem.eql(u8, name, mapped_group)) return true;
    }
    return false;
}

const mapped_groups = [_][]const u8{
    "Blocks",
    "CoreProperties",
    "GeneralCategory",
    "GraphemeBreak",
    "Scripts",
    "ScriptsExtended",
    "SentenceBreak",
    "WordBreak",
};

fn writeEscapedBytes(writer: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| {
        switch (byte) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
            else => try writer.print("\\x{X:0>2}", .{byte}),
        }
    }
}

fn identifier(name: []const u8) Identifier {
    return .{ .name = name };
}

const Identifier = struct {
    name: []const u8,

    pub fn format(id: Identifier, writer: *std.Io.Writer) !void {
        if (isBareIdentifier(id.name)) {
            try writer.writeAll(id.name);
            return;
        }

        try writer.writeAll("@\"");
        try writeEscapedBytes(writer, id.name);
        try writer.writeByte('"');
    }
};

fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return std.zig.Token.getKeyword(name) == null;
}

const header_txt =
    \\//! Generated source!
    \\//! Do not modify!
    \\
    \\
;

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

test "emitRoots writes generated property roots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x42 });
    try db.addRange("Age", "V1_1", .{ .first = 0x41, .last = 0x41 });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("gc ; General_Category");
    try aliases.loadPropertyValueLine("gc ; Lu ; Uppercase_Letter");
    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyValueLine("blk ; ASCII ; Basic_Latin");

    try emitRoots(testing.allocator, .{ .io = testing.io, .dir = tmp.dir }, &db, &aliases);

    inline for (.{ "runicode.zig", "sets.zig", "codepoints.zig", "strs.zig", "enums.zig", "maps.zig" }) |path| {
        var file = try tmp.dir.openFile(testing.io, path, .{});
        file.close(testing.io);
    }

    const runicode = try tmp.dir.readFileAlloc(testing.io, "runicode.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(runicode);
    const strs = try tmp.dir.readFileAlloc(testing.io, "strs.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(strs);

    try testing.expect(std.mem.indexOf(u8, runicode, "pub const sets = @import(\"sets.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const maps = @import(\"maps.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, strs, "pub const GeneralCategory") != null);
    try testing.expect(std.mem.indexOf(u8, strs, "pub const Lu") != null);

    const gencat = try tmp.dir.readFileAlloc(testing.io, "strs/gencat.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(gencat);

    try testing.expect(std.mem.indexOf(u8, gencat, "pub const Lu = @import(\"gencat/Lu.zig\").Lu;") != null);
    try testing.expect(std.mem.indexOf(u8, gencat, "pub const Uppercase_Letter = Lu;") != null);

    const maps = try tmp.dir.readFileAlloc(testing.io, "maps.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(maps);

    try testing.expect(std.mem.indexOf(u8, maps, "pub const GeneralCategory = @import(\"maps/gencat.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const Age") == null);

    const gencat_maps = try tmp.dir.readFileAlloc(testing.io, "maps/gencat.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(gencat_maps);

    try testing.expect(std.mem.indexOf(u8, gencat_maps, "const sets = @import(\"../sets/gencat.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, gencat_maps, "const codepoints = @import(\"../codepoints/gencat.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, gencat_maps, "const strs = @import(\"../strs/gencat.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, gencat_maps, "const enums = @import(\"../enums.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, gencat_maps, "pub const Sets = ucd_tools.NamedMap(sets);") != null);
    try testing.expect(std.mem.indexOf(u8, gencat_maps, "pub const Codepoints = ucd_tools.NamedMap(codepoints);") != null);
    try testing.expect(std.mem.indexOf(u8, gencat_maps, "pub const Strs = ucd_tools.NamedMap(strs);") != null);
}

test "emitRoots writes literal generated leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("Blocks", "Basic_Latin", .{ .first = 0x2D, .last = 0x2F });
    try db.addRange("Blocks", "Basic_Latin", .{ .first = 0x2E, .last = 0x2E });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyValueLine("blk ; ASCII ; Basic_Latin");

    try emitRoots(testing.allocator, .{ .io = testing.io, .dir = tmp.dir }, &db, &aliases);

    const codepoints_root = try tmp.dir.readFileAlloc(testing.io, "codepoints.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(codepoints_root);
    const strs_root = try tmp.dir.readFileAlloc(testing.io, "strs.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(strs_root);
    const sets_root = try tmp.dir.readFileAlloc(testing.io, "sets.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(sets_root);
    const codepoints_group = try tmp.dir.readFileAlloc(testing.io, "codepoints/blocks.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(codepoints_group);
    const codepoints_value = try tmp.dir.readFileAlloc(testing.io, "codepoints/blocks/Basic_Latin.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(codepoints_value);
    const strs_value = try tmp.dir.readFileAlloc(testing.io, "strs/blocks/Basic_Latin.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(strs_value);
    const sets_value = try tmp.dir.readFileAlloc(testing.io, "sets/blocks/Basic_Latin.zig", testing.allocator, .limited(512 * 1024));
    defer testing.allocator.free(sets_value);
    const maps_group = try tmp.dir.readFileAlloc(testing.io, "maps/blocks.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(maps_group);

    try testing.expect(std.mem.indexOf(u8, codepoints_root, "pub const Blocks = @import(\"codepoints/blocks.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, strs_root, "pub const Blocks = @import(\"strs/blocks.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, sets_root, "pub const Blocks = @import(\"sets/blocks.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, codepoints_group, "@import(\"blocks/Basic_Latin.zig\").Basic_Latin") != null);
    try testing.expect(std.mem.indexOf(u8, codepoints_group, "pub const ASCII = Basic_Latin;") != null);
    try testing.expect(std.mem.indexOf(u8, codepoints_value, "pub const Basic_Latin: [3]u21 = .{ 0x2D, 0x2E, 0x2F, };") != null);
    try testing.expect(std.mem.indexOf(u8, strs_value, "pub const Basic_Latin = \"-./\";") != null);
    try testing.expect(std.mem.indexOf(u8, sets_value, "RuneSet") != null);
    try testing.expect(std.mem.indexOf(u8, sets_value, "/// Length: ") != null);
    try testing.expect(std.mem.indexOf(u8, sets_value, "pub const Basic_Latin") != null);
    try testing.expect(std.mem.indexOf(u8, maps_group, "const sets = @import(\"../sets/blocks.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, maps_group, "pub const Codepoints = ucd_tools.NamedMap(codepoints);") != null);
}
