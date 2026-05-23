const std = @import("std");
const audit = @import("ucd/audit.zig");
const alias_data = @import("ucd/aliases.zig");
const db_data = @import("ucd/db.zig");
const emit = @import("ucd/emit.zig");
const manifest = @import("ucd/manifest.zig");
const parse = @import("ucd/parse.zig");
const unicoder = @import("unicoder");
const RuneSet = @import("runeset").RuneSet;
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

    // Composite General_Category values depend on the leaf values already being
    // loaded, and they should be normal DB values before emission starts.
    try addGeneralCategoryAggregates(allocator, &db, &aliases);
    try db.finalizeRuneSets();
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

/// Synthesizes Unicode General_Category aggregate aliases absent from the data.
///
/// The UCD file lists leaf categories (`Lu`, `Ll`, `Nd`, etc.). Property value
/// aliases also define composite categories (`L`, `LC`, `N`, and friends), so we
/// construct those composites here to match caller expectations without parsing
/// comment-only `@missing` defaults.
fn addGeneralCategoryAggregates(allocator: std.mem.Allocator, db: *Db, aliases: *Aliases) !void {
    // Aggregates are only meaningful after the leaf GeneralCategory data exists.
    const group = db.property("GeneralCategory") orelse return;
    for (general_category_aggregates) |aggregate| {
        // The table uses standard short aliases; storing the canonical value name
        // keeps generated filenames and alias lookups consistent with UCD.
        const target = aliases.canonicalValue("gc", aggregate.target) orelse aggregate.target;
        if (group.value(target) != null) continue;

        var aggregate_ranges: std.ArrayList(parse.Range) = .empty;
        defer aggregate_ranges.deinit(allocator);

        for (aggregate.sources) |source_alias| {
            // Source aliases are canonicalized for the same reason as the target:
            // the database stores names after alias resolution, not raw shorts.
            const source = aliases.canonicalValue("gc", source_alias) orelse source_alias;
            const source_value = group.value(source) orelse return error.MissingGeneralCategoryAggregateSource;
            try aggregate_ranges.appendSlice(allocator, source_value.ranges.items);
        }

        if (aggregate_ranges.items.len == 0) return error.InvalidGeneralCategoryAggregate;
        try db.addRanges("GeneralCategory", target, aggregate_ranges.items);
    }
}

/// Description of one synthetic General_Category composite.
///
/// Keeping this as data rather than code makes the Unicode alias relationship
/// auditable: every target shows exactly which leaf categories it contains.
const GeneralCategoryAggregate = struct {
    /// Short or canonical alias for the composite category to synthesize.
    ///
    /// The value is canonicalized before insertion so generated names match the
    /// property-value alias file.
    target: []const u8,

    /// Leaf category aliases whose ranges form the composite.
    ///
    /// Sources are resolved through aliases because the DB stores canonical
    /// names even though the Unicode spec usually describes these sets by short
    /// aliases.
    sources: []const []const u8,
};

/// General_Category composites defined by Unicode property-value aliases.
///
/// These values are not separate rows in `extracted/DerivedGeneralCategory.txt`,
/// but users reasonably expect them because `PropertyValueAliases.txt` names
/// them and regex engines commonly expose them.
const general_category_aggregates = [_]GeneralCategoryAggregate{
    .{ .target = "C", .sources = &.{ "Cc", "Cf", "Cn", "Co", "Cs" } },
    .{ .target = "L", .sources = &.{ "Ll", "Lm", "Lo", "Lt", "Lu" } },
    .{ .target = "LC", .sources = &.{ "Ll", "Lt", "Lu" } },
    .{ .target = "M", .sources = &.{ "Mc", "Me", "Mn" } },
    .{ .target = "N", .sources = &.{ "Nd", "Nl", "No" } },
    .{ .target = "P", .sources = &.{ "Pc", "Pd", "Pe", "Pf", "Pi", "Po", "Ps" } },
    .{ .target = "S", .sources = &.{ "Sc", "Sk", "Sm", "So" } },
    .{ .target = "Z", .sources = &.{ "Zl", "Zp", "Zs" } },
};

fn expectRuneSetCodepoints(expected: []const u21, rune_set: RuneSet) !void {
    var actual: std.ArrayList(u21) = .empty;
    defer actual.deinit(testing.allocator);

    var iter = rune_set.iterateRunes();
    while (iter.next()) |rune| {
        try actual.append(testing.allocator, codepointFromRune(rune));
    }
    try testing.expectEqualSlices(u21, expected, actual.items);
}

fn codepointFromRune(rune: []const u8) u21 {
    var codepoints = unicoder.wtf8.iterator(rune, .assume_valid);
    const codepoint = codepoints.nextCodepoint().?;
    std.debug.assert(codepoints.nextCodepoint() == null);
    return codepoint;
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
    try db.finalizeRuneSets();
    const basic_latin = block.value("Basic Latin").?;
    try expectRuneSetCodepoints(&.{0x1}, basic_latin.rune_set.?);
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
    try db.finalizeRuneSets();
    try expectRuneSetCodepoints(&.{0x1}, block.value("Basic Latin").?.rune_set.?);
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
    try db.finalizeRuneSets();
    try expectRuneSetCodepoints(&.{0x09}, properties.value("White_Space").?.rune_set.?);
    try expectRuneSetCodepoints(&.{0x41}, properties.value("Alphabetic").?.rune_set.?);
    try testing.expect(properties.value("Y") == null);
}

test "general category aggregates synthesize alias targets" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("gc ; General_Category");
    inline for (.{
        "gc ; C ; Other",
        "gc ; L ; Letter",
        "gc ; LC ; Cased_Letter",
        "gc ; M ; Mark ; Combining_Mark",
        "gc ; N ; Number",
        "gc ; P ; Punctuation ; punct",
        "gc ; S ; Symbol",
        "gc ; Z ; Separator",
        "gc ; Cc ; Control ; cntrl",
        "gc ; Cf ; Format",
        "gc ; Cn ; Unassigned",
        "gc ; Co ; Private_Use",
        "gc ; Cs ; Surrogate",
        "gc ; Ll ; Lowercase_Letter",
        "gc ; Lm ; Modifier_Letter",
        "gc ; Lo ; Other_Letter",
        "gc ; Lt ; Titlecase_Letter",
        "gc ; Lu ; Uppercase_Letter",
        "gc ; Mc ; Spacing_Mark",
        "gc ; Me ; Enclosing_Mark",
        "gc ; Mn ; Nonspacing_Mark",
        "gc ; Nd ; Decimal_Number ; digit",
        "gc ; Nl ; Letter_Number",
        "gc ; No ; Other_Number",
        "gc ; Pc ; Connector_Punctuation",
        "gc ; Pd ; Dash_Punctuation",
        "gc ; Pe ; Close_Punctuation",
        "gc ; Pf ; Final_Punctuation",
        "gc ; Pi ; Initial_Punctuation",
        "gc ; Po ; Other_Punctuation",
        "gc ; Ps ; Open_Punctuation",
        "gc ; Sc ; Currency_Symbol",
        "gc ; Sk ; Modifier_Symbol",
        "gc ; Sm ; Math_Symbol",
        "gc ; So ; Other_Symbol",
        "gc ; Zl ; Line_Separator",
        "gc ; Zp ; Paragraph_Separator",
        "gc ; Zs ; Space_Separator",
    }) |line| try aliases.loadPropertyValueLine(line);

    var db = Db.init(testing.allocator);
    defer db.deinit();

    inline for (.{
        "Cc", "Cf", "Cn", "Co", "Cs",
        "Ll", "Lm", "Lo", "Lt", "Lu",
        "Mc", "Me", "Mn", "Nd", "Nl",
        "No", "Pc", "Pd", "Pe", "Pf",
        "Pi", "Po", "Ps", "Sc", "Sk",
        "Sm", "So", "Zl", "Zp", "Zs",
    }, 0..) |short, idx| {
        const value = aliases.canonicalValue("gc", short).?;
        const codepoint: u21 = @intCast(0x100 + idx);
        try db.addRange("GeneralCategory", value, .{ .first = codepoint, .last = codepoint });
    }

    try addGeneralCategoryAggregates(testing.allocator, &db, &aliases);
    try db.finalizeRuneSets();

    const group = db.property("GeneralCategory").?;
    try testing.expectEqual(@as(usize, 5), group.value("Letter").?.rune_set.?.runeCount());
    try testing.expectEqual(@as(usize, 3), group.value("Cased_Letter").?.rune_set.?.runeCount());
    try testing.expectEqual(@as(usize, 7), group.value("Punctuation").?.rune_set.?.runeCount());
    try testing.expectEqual(@as(usize, 3), group.value("Separator").?.rune_set.?.runeCount());
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
    try db.finalizeRuneSets();
    try expectRuneSetCodepoints(&.{ 0x0, 0x1, 0x2 }, scripts_extended.value("Latin").?.rune_set.?);
    try expectRuneSetCodepoints(&.{ 0x1, 0x3 }, scripts_extended.value("Greek").?.rune_set.?);
    try expectRuneSetCodepoints(&.{0x2}, scripts_extended.value("Cyrillic").?.rune_set.?);
}
