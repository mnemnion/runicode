const std = @import("std");
const audit = @import("ucd/audit.zig");
const alias_data = @import("ucd/aliases.zig");
const db_data = @import("ucd/db.zig");
const emit = @import("ucd/emit.zig");
const manifest = @import("ucd/manifest.zig");
const parse = @import("ucd/parse.zig");
const testing = std.testing;

const Aliases = alias_data.Aliases;
const Db = db_data.Db;
const PropertyGroup = db_data.PropertyGroup;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len != 3) return error.InvalidArguments;

    var ucd_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer ucd_dir.close(io);
    try std.Io.Dir.cwd().deleteTree(io, argv[2]);
    try std.Io.Dir.cwd().createDirPath(io, argv[2]);
    var out_dir = try std.Io.Dir.cwd().openDir(io, argv[2], .{});
    defer out_dir.close(io);

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
    for (manifest.known_files) |entry| {
        switch (entry.kind) {
            .script_extensions => try readScriptExtensionsFile(io, allocator, ucd_dir, &db, &aliases, entry),
            else => {},
        }
    }
    try emit.emitRoots(allocator, .{
        .io = io,
        .dir = out_dir,
    }, &db, &aliases);

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

    var in_buf: [4096]u8 = undefined;
    var in_reader = file.reader(io, &in_buf);
    while (try in_reader.interface.takeDelimiter('\n')) |line| {
        var field_list = try parse.fields(allocator, line);
        defer field_list.deinit(allocator);

        if (field_list.items.len == 0) continue;
        if (field_list.items.len < 2 or field_list.items.len > 3) return error.InvalidCodepointPropertyLine;

        const range = try parse.parseCodepointRange(field_list.items[0]);
        const raw_property = entry.property orelse field_list.items[1];
        const canonical_property = aliases.canonicalProperty(raw_property) orelse raw_property;
        const property = entry.namespace orelse canonical_property;
        const raw_value = if (entry.property != null)
            field_list.items[1]
        else if (field_list.items.len == 3)
            field_list.items[2]
        else
            canonical_property;
        const value = aliases.canonicalValue(canonical_property, raw_value) orelse raw_value;

        try db.addRange(property, value, range);
    }
}

fn readScriptExtensionsFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *Aliases,
    entry: manifest.UcdFile,
) !void {
    const namespace = entry.namespace orelse return error.InvalidScriptExtensionsEntry;
    const scripts = db.property("Scripts") orelse return error.MissingScripts;
    try copyGroupRanges(db, namespace, scripts);

    var file = try ucd_dir.openFile(io, entry.path, .{});
    defer file.close(io);

    var in_buf: [4096]u8 = undefined;
    var in_reader = file.reader(io, &in_buf);
    while (try in_reader.interface.takeDelimiter('\n')) |line| {
        var field_list = try parse.fields(allocator, line);
        defer field_list.deinit(allocator);

        if (field_list.items.len == 0) continue;
        if (field_list.items.len != 2) return error.InvalidScriptExtensionsLine;

        const range = try parse.parseCodepointRange(field_list.items[0]);
        var script_it = std.mem.tokenizeAny(u8, field_list.items[1], " \t");
        while (script_it.next()) |raw_script| {
            const script = aliases.canonicalValue("sc", raw_script) orelse raw_script;
            try db.addRange(namespace, script, range);
        }
    }
}

fn copyGroupRanges(db: *Db, dest_name: []const u8, source: *const PropertyGroup) !void {
    var it = source.values.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.ranges.items) |range| {
            try db.addRange(dest_name, entry.key_ptr.*, range);
        }
    }
}

test "codepoint property reader ignores comment defaults" {
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

    const block = db.property("Blocks").?;
    try testing.expect(block.value("No_Block") == null);
    const basic_latin = block.value("Basic Latin").?;
    try testing.expectEqualSlices(u21, &.{0x1}, basic_latin.codepoints.items);
}

test "codepoint property reader ignores comment-only files" {
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

    try testing.expect(db.property("BidiClass") == null);
}

test "codepoint property reader ignores malformed missing comments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Blocks.txt",
        .data =
        \\# @missing: not-a-range; No_Block
        \\0001; Basic Latin
        \\
        ,
    });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyValueLine("blk ; Basic_Latin ; Basic Latin");

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try readCodepointPropertyFile(testing.io, testing.allocator, tmp.dir, &db, &aliases, .{
        .path = "Blocks.txt",
        .kind = .codepoint_property,
        .property = "blk",
        .namespace = "Blocks",
    });

    const block = db.property("Blocks").?;
    try testing.expectEqualSlices(u21, &.{0x1}, block.value("Basic Latin").?.codepoints.items);
}

test "codepoint property reader keeps grouped binary properties separate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "PropList.txt",
        .data =
        \\0009; White_Space
        \\0041; Alphabetic
        \\
        ,
    });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try readCodepointPropertyFile(testing.io, testing.allocator, tmp.dir, &db, &aliases, .{
        .path = "PropList.txt",
        .kind = .codepoint_property,
        .namespace = "Properties",
    });

    const properties = db.property("Properties").?;
    try testing.expectEqualSlices(u21, &.{0x09}, properties.value("White_Space").?.codepoints.items);
    try testing.expectEqualSlices(u21, &.{0x41}, properties.value("Alphabetic").?.codepoints.items);
    try testing.expect(properties.value("Y") == null);
}

test "script extensions inherit scripts and add explicit script values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Scripts.txt",
        .data =
        \\0000..0002; Latn
        \\0003; Grek
        \\
        ,
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "ScriptExtensions.txt",
        .data =
        \\0001; Grek
        \\0002; Cyrl Latn
        \\# @missing: 0000..10FFFF; <script>
        \\
        ,
    });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("sc ; Script");
    try aliases.loadPropertyLine("scx ; Script_Extensions");
    try aliases.loadPropertyValueLine("sc ; Latn ; Latin");
    try aliases.loadPropertyValueLine("sc ; Grek ; Greek");
    try aliases.loadPropertyValueLine("sc ; Cyrl ; Cyrillic");

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try readCodepointPropertyFile(testing.io, testing.allocator, tmp.dir, &db, &aliases, .{
        .path = "Scripts.txt",
        .kind = .codepoint_property,
        .property = "sc",
        .namespace = "Scripts",
    });
    try readScriptExtensionsFile(testing.io, testing.allocator, tmp.dir, &db, &aliases, .{
        .path = "ScriptExtensions.txt",
        .kind = .script_extensions,
        .property = "scx",
        .namespace = "ScriptsExtended",
    });

    const scripts_extended = db.property("ScriptsExtended").?;
    try testing.expectEqualSlices(u21, &.{ 0x0, 0x1, 0x2, 0x2 }, scripts_extended.value("Latin").?.codepoints.items);
    try testing.expectEqualSlices(u21, &.{ 0x3, 0x1 }, scripts_extended.value("Greek").?.codepoints.items);
    try testing.expectEqualSlices(u21, &.{0x2}, scripts_extended.value("Cyrillic").?.codepoints.items);
}
