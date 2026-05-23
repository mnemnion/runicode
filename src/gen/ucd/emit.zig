const std = @import("std");
const testing = std.testing;

const Db = @import("db.zig").Db;
const RuneSet = LocalRuneSet;

pub const OutputDir = struct {
    io: std.Io,
    dir: std.Io.Dir,
    sets_path: []const u8 = "sets.zig",
    codepoints_path: []const u8 = "codepoints.zig",
    strs_path: []const u8 = "strs.zig",
    enums_path: []const u8 = "enums.zig",
    maps_path: []const u8 = "maps.zig",
};

pub fn emitRoots(allocator: std.mem.Allocator, dir: OutputDir, db: *Db) !void {
    const group_names = try sortedGroupNames(allocator, db);
    defer allocator.free(group_names);

    try writeRootFile(dir, dir.strs_path, writeStrsRoot, .{ group_names, db });
    try writeRootFile(dir, dir.codepoints_path, writeCodepointsRoot, .{ group_names, db });
    try writeRootFile(dir, dir.sets_path, writeSetsRoot, .{ allocator, group_names, db });
    try writeRootFile(dir, dir.enums_path, writeEnumsRoot, .{ group_names, db });
    try writeRootFile(dir, dir.maps_path, writeMapsRoot, .{group_names});
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

fn writeStrsRoot(writer: *std.Io.Writer, group_names: []const []const u8, db: *Db) !void {
    try writer.writeAll(header_txt);
    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        try writer.print("pub const {f} = struct {{\n", .{identifier(group_name)});
        for (value_names) |value_name| {
            const value = group.value(value_name).?;
            try writer.print("    pub const {f} = \"", .{identifier(value_name)});
            try writeEscapedBytes(writer, value.utf8.items);
            try writer.writeAll("\";\n");
        }
        try writer.writeAll("};\n\n");
    }
}

fn writeCodepointsRoot(writer: *std.Io.Writer, group_names: []const []const u8, db: *Db) !void {
    try writer.writeAll(header_txt);
    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        try writer.print("pub const {f} = struct {{\n", .{identifier(group_name)});
        for (value_names) |value_name| {
            const codepoints = group.value(value_name).?.codepoints.items;
            try writer.print("    pub const {f}: [{d}]u21 = .{{", .{ identifier(value_name), codepoints.len });
            for (codepoints) |codepoint| {
                try writer.print(" 0x{X},", .{codepoint});
            }
            try writer.writeAll(" };\n");
        }
        try writer.writeAll("};\n\n");
    }
}

fn writeSetsRoot(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    group_names: []const []const u8,
    db: *Db,
) !void {
    try writer.writeAll(header_txt);
    try writer.writeAll("const RuneSet = @import(\"runeset\").RuneSet;\n\n");
    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        try writer.print("pub const {f} = struct {{\n", .{identifier(group_name)});
        for (value_names) |value_name| {
            const value = group.value(value_name).?;
            const rune_set = try RuneSet.createFromConstString(value.utf8.items, allocator);
            defer rune_set.deinit(allocator);
            const set_name = try ownedIdentifier(allocator, value_name);
            defer if (set_name.ptr != value_name.ptr) allocator.free(set_name);
            try writer.print("    // Length: {d}.\n    ", .{rune_set.body.len});
            try rune_set.serialize(writer, .public, set_name);
        }
        try writer.writeAll("};\n\n");
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
            try writer.print("    {f},\n", .{identifier(value_name)});
        }
        try writer.writeAll("};\n\n");
    }
}

fn writeMapsRoot(writer: *std.Io.Writer, group_names: []const []const u8) !void {
    try writer.writeAll(header_txt);
    try writer.writeAll(
        \\const ucd_tools = @import("ucd-tools");
        \\const sets = @import("generated_sets");
        \\const codepoints = @import("generated_codepoints");
        \\const strs = @import("generated_strs");
        \\const enums = @import("generated_enums");
        \\
        \\
    );

    for (group_names) |group_name| {
        try writer.print(
            \\pub const {f} = struct {{
            \\    pub const Sets = ucd_tools.NamedMap(sets.{f});
            \\    pub const Codepoints = ucd_tools.NamedMap(codepoints.{f});
            \\    pub const Strs = ucd_tools.NamedMap(strs.{f});
            \\    pub const Enum = enums.{f};
            \\}};
            \\
            \\
        , .{
            identifier(group_name),
            identifier(group_name),
            identifier(group_name),
            identifier(group_name),
            identifier(group_name),
        });
    }
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

fn ownedIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (isBareIdentifier(name)) return name;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "@\"");
    for (name) |byte| switch (byte) {
        '"' => try result.appendSlice(allocator, "\\\""),
        '\\' => try result.appendSlice(allocator, "\\\\"),
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try result.append(allocator, byte),
        else => {
            var buf: [4]u8 = undefined;
            const escaped = try std.fmt.bufPrint(&buf, "\\x{X:0>2}", .{byte});
            try result.appendSlice(allocator, escaped);
        },
    };
    try result.append(allocator, '"');
    return try result.toOwnedSlice(allocator);
}

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

const LocalRuneSet = struct {
    body: []const u64,

    fn deinit(set: LocalRuneSet, allocator: std.mem.Allocator) void {
        allocator.free(set.body);
    }

    fn createFromConstString(str: []const u8, allocator: std.mem.Allocator) !LocalRuneSet {
        const mutable = try allocator.dupe(u8, str);
        defer allocator.free(mutable);
        return .{ .body = try createBodyFromString(mutable, allocator) };
    }

    fn serialize(set: LocalRuneSet, writer: *std.Io.Writer, public: Privacy, name: []const u8) !void {
        if (public == .public) try writer.writeAll("pub ");
        try writer.print("const {s} = RuneSet{{ .body = &.{{ 0x{x}", .{ name, set.body[0] });
        for (set.body[1..]) |word| {
            try writer.print(", 0x{x}", .{word});
        }
        try writer.writeAll(" } };\n");
    }

    const Privacy = enum { private, public };
};

const LOW = 0;
const HI = 1;
const LEAD = 2;
const T4_OFF = 3;
const TWO_MAX = 32;
const THREE_MAX = 48;
const FOUR_MAX = 56;

const InvalidUnicode = error.InvalidUnicode;

const RuneKind = enum(u2) {
    low,
    hi,
    follow,
    lead,
};

const CodeUnit = packed struct(u8) {
    body: u6,
    kind: RuneKind,

    fn inMask(cu: CodeUnit) u64 {
        return @as(u64, 1) << cu.body;
    }

    fn nMultiBytes(cu: CodeUnit) ?u8 {
        std.debug.assert(cu.kind == .lead);
        return switch (cu.body) {
            0...31 => 2,
            32...47 => 3,
            48...55 => 4,
            56...63 => null,
        };
    }

    fn hiMask(cu: CodeUnit) u64 {
        return (@as(u64, 1) << cu.body) - 1;
    }

    fn lowMask(cu: CodeUnit) u64 {
        return if (cu.body == 63) 0 else ~((@as(u64, 1) << (cu.body + 1)) - 1);
    }
};

const Mask = struct {
    m: u64,

    fn add(mask: *Mask, cu: CodeUnit) void {
        mask.m |= cu.inMask();
    }

    fn isIn(mask: Mask, cu: CodeUnit) bool {
        return mask.m | cu.inMask() == mask.m;
    }

    fn higherThan(mask: Mask, cu: CodeUnit) ?u64 {
        if (!mask.isIn(cu)) return null;
        return @popCount(mask.m & cu.lowMask());
    }

    fn lowerThan(mask: Mask, cu: CodeUnit) ?u64 {
        if (!mask.isIn(cu)) return null;
        return @popCount(mask.m & cu.hiMask());
    }

    fn count(mask: Mask) usize {
        return @popCount(mask.m);
    }
};

fn codeunit(byte: u8) CodeUnit {
    return @bitCast(byte);
}

fn toMask(word: u64) Mask {
    return .{ .m = word };
}

fn createBodyFromString(str: []u8, allocator: std.mem.Allocator) ![]u64 {
    var header: [4]u64 = .{0} ** 4;
    var back: usize = 0;
    var sieve = str;

    var idx: usize = 0;
    var low = toMask(0);
    var hi = toMask(0);
    var lead = toMask(0);
    while (idx < sieve.len) {
        const cu = codeunit(sieve[idx]);
        switch (cu.kind) {
            .low => {
                low.add(cu);
                back += 1;
                idx += 1;
            },
            .hi => {
                hi.add(cu);
                back += 1;
                idx += 1;
            },
            .lead => {
                lead.add(cu);
                const byte_count = cu.nMultiBytes() orelse return InvalidUnicode;
                if (idx + byte_count > sieve.len) return InvalidUnicode;
                if (byte_count >= 2) {
                    sieve[idx - back] = sieve[idx];
                    sieve[idx - back + 1] = sieve[idx + 1];
                }
                if (byte_count >= 3) sieve[idx - back + 2] = sieve[idx + 2];
                if (byte_count == 4) sieve[idx - back + 3] = sieve[idx + 3];
                idx += byte_count;
            },
            .follow => return InvalidUnicode,
        }
    }

    header[LOW] = low.m;
    header[HI] = hi.m;
    if (lead.count() == 0) {
        const body = try allocator.alloc(u64, 4);
        @memcpy(body, &header);
        return body;
    }

    sieve = sieve[0 .. sieve.len - back];
    var t2: [FOUR_MAX + 1]u64 = .{0} ** (FOUR_MAX + 1);
    idx = 0;
    back = 0;
    while (idx < sieve.len) {
        const one = codeunit(sieve[idx]);
        const byte_count = one.nMultiBytes() orelse return InvalidUnicode;
        if (idx + byte_count > sieve.len) return InvalidUnicode;
        const two = codeunit(sieve[idx + 1]);
        if (two.kind != .follow) return InvalidUnicode;
        var two_mask = toMask(t2[one.body]);
        two_mask.add(two);
        t2[one.body] = two_mask.m;
        if (byte_count == 2) {
            back += 2;
        } else {
            sieve[idx - back] = sieve[idx];
            sieve[idx - back + 1] = sieve[idx + 1];
            sieve[idx - back + 2] = sieve[idx + 2];
            if (byte_count == 4) sieve[idx - back + 3] = sieve[idx + 3];
        }
        idx += byte_count;
    }

    header[LEAD] = lead.m;
    if (sieve.len == back) {
        const t2_compact = compactSlice(&t2);
        const body = try allocator.alloc(u64, 4 + t2_compact.len);
        @memcpy(body[0..4], &header);
        @memcpy(body[4..], t2_compact);
        return body;
    }

    sieve = sieve[0 .. sieve.len - back];
    const t3 = try allocator.alloc(u64, popCountSlice(t2[TWO_MAX..]));
    defer allocator.free(t3);
    @memset(t3, 0);

    idx = 0;
    back = 0;
    while (idx < sieve.len) {
        const one = codeunit(sieve[idx]);
        const byte_count = one.nMultiBytes().?;
        const two = codeunit(sieve[idx + 1]);
        const two_mask = toMask(t2[one.body]);
        const three_off = two_mask.higherThan(two).? + popCountSlice(t2[one.body + 1 ..]);
        const three = codeunit(sieve[idx + 2]);
        if (three.kind != .follow) return InvalidUnicode;
        var three_mask = toMask(t3[three_off]);
        three_mask.add(three);
        t3[three_off] = three_mask.m;
        if (byte_count == 3) {
            back += 3;
        } else {
            sieve[idx - back] = sieve[idx];
            sieve[idx - back + 1] = sieve[idx + 1];
            sieve[idx - back + 2] = sieve[idx + 2];
            sieve[idx - back + 3] = sieve[idx + 3];
        }
        idx += byte_count;
    }

    if (sieve.len == back) {
        const t2_compact = compactSlice(&t2);
        const t3_off = 4 + t2_compact.len;
        const body = try allocator.alloc(u64, t3_off + t3.len);
        @memcpy(body[0..4], &header);
        @memcpy(body[4..t3_off], t2_compact);
        @memcpy(body[t3_off..], t3);
        return body;
    }

    sieve = sieve[0 .. sieve.len - back];
    const t4_head = 4 + nonZeroCount(&t2) + popCountSlice(t2[TWO_MAX..]);
    header[T4_OFF] = t4_head;

    const elem4 = popCountSlice(t2[THREE_MAX..]);
    const t4 = try allocator.alloc(u64, popCountSlice(t3[0..elem4]));
    defer allocator.free(t4);
    @memset(t4, 0);

    idx = 0;
    while (idx < sieve.len) {
        const one = codeunit(sieve[idx]);
        const byte_count = one.nMultiBytes().?;
        const two = codeunit(sieve[idx + 1]);
        const two_mask = toMask(t2[one.body]);
        const three_off = two_mask.higherThan(two).? + popCountSlice(t2[one.body + 1 ..]);
        const three = codeunit(sieve[idx + 2]);
        const three_mask = toMask(t3[three_off]);
        const four_off = three_mask.lowerThan(three).? + popCountSlice(t3[0..three_off]);
        if (idx + 3 >= sieve.len) return InvalidUnicode;
        const four = codeunit(sieve[idx + 3]);
        if (four.kind != .follow) return InvalidUnicode;
        var four_mask = toMask(t4[four_off]);
        four_mask.add(four);
        t4[four_off] = four_mask.m;
        idx += byte_count;
    }

    const t2_compact = compactSlice(&t2);
    const t3_off = 4 + t2_compact.len;
    const t4_off = header[T4_OFF];
    const body = try allocator.alloc(u64, t4_off + t4.len);
    @memcpy(body[0..4], &header);
    @memcpy(body[4..t3_off], t2_compact);
    @memcpy(body[t3_off..t4_off], t3);
    @memcpy(body[t4_off..], t4);
    return body;
}

fn compactSlice(slice: []u64) []u64 {
    var write: usize = 0;
    for (slice) |word| {
        if (word == 0) continue;
        slice[write] = word;
        write += 1;
    }
    return slice[0..write];
}

fn nonZeroCount(words: []const u64) usize {
    var count: usize = 0;
    for (words) |word| {
        if (word != 0) count += 1;
    }
    return count;
}

fn popCountSlice(words: []const u64) usize {
    var count: usize = 0;
    for (words) |word| count += @popCount(word);
    return count;
}

test "emitRoots writes generated property roots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x42 });

    try emitRoots(testing.allocator, .{ .io = testing.io, .dir = tmp.dir }, &db);

    inline for (.{ "sets.zig", "codepoints.zig", "strs.zig", "enums.zig", "maps.zig" }) |path| {
        var file = try tmp.dir.openFile(testing.io, path, .{});
        file.close(testing.io);
    }

    const strs = try tmp.dir.readFileAlloc(testing.io, "strs.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(strs);

    try testing.expect(std.mem.indexOf(u8, strs, "pub const GeneralCategory") != null);
    try testing.expect(std.mem.indexOf(u8, strs, "pub const Lu") != null);
}
