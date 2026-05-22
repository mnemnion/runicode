const std = @import("std");
const audit = @import("ucd/audit.zig");
const alias_data = @import("ucd/aliases.zig");
const Db = @import("ucd/db.zig").Db;
const manifest = @import("ucd/manifest.zig");
const parse = @import("ucd/parse.zig");
const testing = std.testing;

const Aliases = alias_data.Aliases;

const PropertyRange = struct {
    property: []const u8,
    range: parse.Range,
};

const MissingAssignment = struct {
    property: []const u8,
    value: []const u8,
    range: parse.Range,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len < 2) return error.InvalidArguments;

    var ucd_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer ucd_dir.close(io);

    try audit.auditDir(io, allocator, ucd_dir);
    var aliases = alias_data.Aliases.init(allocator);
    defer aliases.deinit();

    try aliases.loadPropertyAliasesFile(io, ucd_dir);
    try aliases.loadPropertyValueAliasesFile(io, ucd_dir);

    var db = Db.init(allocator);
    defer db.deinit();

    for (manifest.known_files) |entry| {
        switch (entry.kind) {
            .codepoint_property => try readCodepointPropertyFile(io, allocator, ucd_dir, &db, &aliases, entry),
            else => {},
        }
    }

    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.print("runicode-gen: loaded {d} property groups\n", .{db.propertyCount()});
    try stdout_writer.interface.flush();

    std.process.cleanExit(io);
}

fn readCodepointPropertyFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *Aliases,
    entry: manifest.UcdFile,
) !void {
    var file = try ucd_dir.openFile(io, entry.path, .{});
    defer file.close(io);

    var explicit_ranges: std.ArrayList(PropertyRange) = .empty;
    defer explicit_ranges.deinit(allocator);
    defer freePropertyRanges(allocator, explicit_ranges.items);

    var missing_assignments: std.ArrayList(MissingAssignment) = .empty;
    defer missing_assignments.deinit(allocator);
    defer freeMissingAssignments(allocator, missing_assignments.items);

    var in_buf: [4096]u8 = undefined;
    var in_reader = file.reader(io, &in_buf);
    while (try in_reader.interface.takeDelimiter('\n')) |line| {
        const is_missing = isMissingLine(line);
        var field_list = try codepointPropertyFields(allocator, line);
        defer field_list.deinit(allocator);

        if (field_list.items.len == 0) continue;
        if (field_list.items.len < 2 or field_list.items.len > 3) return error.InvalidCodepointPropertyLine;

        const range = try parse.parseCodepointRange(field_list.items[0]);
        const raw_property = entry.property orelse field_list.items[1];
        const property = aliases.canonicalProperty(raw_property) orelse raw_property;
        const raw_value = if (entry.property != null)
            field_list.items[1]
        else if (field_list.items.len == 3)
            field_list.items[2]
        else
            "Y";
        const value = aliases.canonicalValue(property, raw_value) orelse raw_value;

        if (is_missing) {
            try appendMissingAssignment(allocator, &missing_assignments, property, value, range);
        } else {
            try db.addRange(property, value, range);
            try appendPropertyRange(allocator, &explicit_ranges, property, range);
        }
    }

    try applyMissingAssignments(allocator, db, explicit_ranges.items, missing_assignments.items);
}

fn codepointPropertyFields(allocator: std.mem.Allocator, line: []const u8) !parse.FieldList {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const missing_prefix = "# @missing:";
    if (!std.mem.startsWith(u8, trimmed, missing_prefix)) {
        return parse.fields(allocator, line);
    }
    return parse.fields(allocator, trimmed[missing_prefix.len..]);
}

fn isMissingLine(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r\n"), "# @missing:");
}

fn appendPropertyRange(
    allocator: std.mem.Allocator,
    ranges: *std.ArrayList(PropertyRange),
    property: []const u8,
    range: parse.Range,
) !void {
    const owned_property = try allocator.dupe(u8, property);
    errdefer allocator.free(owned_property);
    try ranges.append(allocator, .{ .property = owned_property, .range = range });
}

fn appendMissingAssignment(
    allocator: std.mem.Allocator,
    assignments: *std.ArrayList(MissingAssignment),
    property: []const u8,
    value: []const u8,
    range: parse.Range,
) !void {
    const owned_property = try allocator.dupe(u8, property);
    errdefer allocator.free(owned_property);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try assignments.append(allocator, .{
        .property = owned_property,
        .value = owned_value,
        .range = range,
    });
}

fn freePropertyRanges(allocator: std.mem.Allocator, ranges: []PropertyRange) void {
    for (ranges) |range| allocator.free(range.property);
}

fn freeMissingAssignments(allocator: std.mem.Allocator, assignments: []MissingAssignment) void {
    for (assignments) |assignment| {
        allocator.free(assignment.property);
        allocator.free(assignment.value);
    }
}

fn applyMissingAssignments(
    allocator: std.mem.Allocator,
    db: *Db,
    explicit_ranges: []const PropertyRange,
    missing_assignments: []const MissingAssignment,
) !void {
    for (missing_assignments, 0..) |assignment, assignment_index| {
        var pieces: std.ArrayList(parse.Range) = .empty;
        defer pieces.deinit(allocator);
        try pieces.append(allocator, assignment.range);

        for (explicit_ranges) |explicit| {
            if (!std.mem.eql(u8, assignment.property, explicit.property)) continue;
            try subtractRange(allocator, &pieces, explicit.range);
        }

        for (missing_assignments[assignment_index + 1 ..]) |later| {
            if (!std.mem.eql(u8, assignment.property, later.property)) continue;
            try subtractRange(allocator, &pieces, later.range);
        }

        for (pieces.items) |range| {
            try db.addRange(assignment.property, assignment.value, range);
        }
    }
}

fn subtractRange(
    allocator: std.mem.Allocator,
    pieces: *std.ArrayList(parse.Range),
    covered: parse.Range,
) !void {
    var remaining: std.ArrayList(parse.Range) = .empty;
    errdefer remaining.deinit(allocator);

    for (pieces.items) |piece| {
        if (covered.first > piece.last or covered.last < piece.first) {
            try remaining.append(allocator, piece);
            continue;
        }
        if (covered.first > piece.first) {
            try remaining.append(allocator, .{
                .first = piece.first,
                .last = covered.first - 1,
            });
        }
        if (covered.last < piece.last) {
            try remaining.append(allocator, .{
                .first = covered.last + 1,
                .last = piece.last,
            });
        }
    }

    pieces.deinit(allocator);
    pieces.* = remaining;
}

test "codepoint property reader applies missing defaults" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Blocks.txt",
        .data =
        \\# @missing: 0000..0002; No_Block
        \\0001; Basic Latin
        \\
        ,
    });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyValueLine("blk ; NB ; No_Block");
    try aliases.loadPropertyValueLine("blk ; Basic_Latin ; Basic Latin");

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try readCodepointPropertyFile(testing.io, testing.allocator, tmp.dir, &db, &aliases, .{
        .path = "Blocks.txt",
        .kind = .codepoint_property,
        .property = "blk",
        .namespace = "Blocks",
    });

    const block = db.property("Block").?;
    const missing = block.value("No_Block").?;
    try testing.expectEqualSlices(u21, &.{ 0x0, 0x2 }, missing.codepoints.items);
    const basic_latin = block.value("Basic Latin").?;
    try testing.expectEqualSlices(u21, &.{0x1}, basic_latin.codepoints.items);
}

test "codepoint property reader gives later missing defaults precedence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Bidi.txt",
        .data =
        \\# @missing: 0000..0002; Left_To_Right
        \\# @missing: 0001..0002; Right_To_Left
        \\
        ,
    });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("bc ; Bidi_Class");
    try aliases.loadPropertyValueLine("bc ; L ; Left_To_Right");
    try aliases.loadPropertyValueLine("bc ; R ; Right_To_Left");

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try readCodepointPropertyFile(testing.io, testing.allocator, tmp.dir, &db, &aliases, .{
        .path = "Bidi.txt",
        .kind = .codepoint_property,
        .property = "bc",
        .namespace = "BidiClass",
    });

    const bidi = db.property("Bidi_Class").?;
    try testing.expectEqualSlices(u21, &.{0x0}, bidi.value("Left_To_Right").?.codepoints.items);
    try testing.expectEqualSlices(u21, &.{ 0x1, 0x2 }, bidi.value("Right_To_Left").?.codepoints.items);
}
