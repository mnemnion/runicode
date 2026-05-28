const std = @import("std");
const testing = std.testing;

const alias_data = @import("aliases.zig");
const emit = @import("emit.zig");
const jobs_data = @import("jobs.zig");
const manifest = @import("manifest.zig");
const parse = @import("parse.zig");
const unicoder = @import("unicoder");
const RuneSet = @import("runeset").RuneSet;

const Aliases = alias_data.Aliases;

pub const PropertyValue = struct {
    pub const empty: PropertyValue = .{};

    pub const RangeList = std.ArrayList(parse.Range);

    ranges: RangeList = .empty,
    rune_set: ?RuneSet = null,

    fn deinit(value: *PropertyValue, allocator: std.mem.Allocator) void {
        value.ranges.deinit(allocator);
        if (value.rune_set) |set| set.deinit(allocator);
    }
};

pub const PropertyGroup = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMapUnmanaged(PropertyValue) = .empty,

    fn init(allocator: std.mem.Allocator) PropertyGroup {
        return .{ .allocator = allocator };
    }

    fn deinit(group: *PropertyGroup) void {
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

    fn init(allocator: std.mem.Allocator) Db {
        return .{ .allocator = allocator };
    }

    fn deinit(db: *Db) void {
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

    fn addRange(db: *Db, property_name: []const u8, value_name: []const u8, range: parse.Range) !void {
        try db.addRanges(property_name, value_name, &.{range});
    }

    fn addRanges(db: *Db, property_name: []const u8, value_name: []const u8, ranges: []const parse.Range) !void {
        if (ranges.len == 0) return error.EmptyRangeSet;

        const group = try db.getOrPutProperty(property_name);
        const prop_value = try group.getOrPutValue(value_name);
        try prop_value.ranges.appendSlice(db.allocator, ranges);
    }

    fn finalizeRuneSets(db: *Db) !void {
        var group_it = db.groups.iterator();
        while (group_it.next()) |group_entry| {
            var value_it = group_entry.value_ptr.values.iterator();
            while (value_it.next()) |value_entry| {
                const value = value_entry.value_ptr;
                if (value.rune_set != null) return error.RuneSetAlreadyFinalized;
                if (value.ranges.items.len == 0) return error.EmptyRangeSet;
                value.rune_set = try createRuneSetFromRanges(value.ranges.items, db.allocator);
            }
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

fn createRuneSetFromRanges(ranges: []const parse.Range, allocator: std.mem.Allocator) !RuneSet {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    for (ranges) |range| {
        var codepoint = range.first;
        while (codepoint <= range.last) : (codepoint += 1) {
            var buf: [4]u8 = undefined;
            const len = try unicoder.codepoint.toWtf8(codepoint, &buf);
            try bytes.appendSlice(allocator, buf[0..len]);
        }
    }

    return try RuneSet.createFromMutableString(bytes.items, allocator);
}

pub const WorkerStats = struct {
    groups: []const emit.GroupMeta,
    metadata_allocator: std.mem.Allocator,

    pub fn deinit(stats: WorkerStats) void {
        emit.freeGroupMeta(stats.metadata_allocator, stats.groups);
    }
};

pub fn runJob(
    io: std.Io,
    gpa: std.mem.Allocator,
    ucd_dir: std.Io.Dir,
    out_dir: std.Io.Dir,
    aliases: *const Aliases,
    job: jobs_data.Job,
    kinds: emit.GeneratedKinds,
) anyerror!WorkerStats {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db = Db.init(allocator);
    defer db.deinit();

    switch (job.kind) {
        .namespace, .core_properties => {
            for (job.entries) |entry| try readEntry(io, ucd_dir, &db, aliases, entry);
        },
        .general_category => {
            for (job.entries) |entry| try readEntry(io, ucd_dir, &db, aliases, entry);
            try addGeneralCategoryAggregates(allocator, &db, aliases);
        },
        .scripts_bundle => try readScriptsBundle(io, ucd_dir, &db, aliases, job),
    }

    try db.finalizeRuneSets();
    const groups = try emit.emitGroupsOwned(allocator, gpa, .{ .io = io, .dir = out_dir, .kinds = kinds }, &db, aliases);
    return .{
        .groups = groups,
        .metadata_allocator = gpa,
    };
}

fn readEntry(
    io: std.Io,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *const Aliases,
    entry: manifest.UcdFile,
) !void {
    switch (entry.kind) {
        .codepoint_property => try readCodepointPropertyFile(io, ucd_dir, db, aliases, entry),
        else => return error.UnsupportedWorkerEntry,
    }
}

fn readScriptsBundle(
    io: std.Io,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *const Aliases,
    job: jobs_data.Job,
) !void {
    for (job.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "Scripts.txt")) {
            try readCodepointPropertyFile(io, ucd_dir, db, aliases, entry);
        }
    }
    for (job.entries) |entry| {
        if (entry.kind == .script_extensions) {
            try readScriptExtensionsFile(io, ucd_dir, db, aliases, entry);
        }
    }
}

fn readCodepointPropertyFile(
    io: std.Io,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *const Aliases,
    entry: manifest.UcdFile,
) !void {
    var file = try ucd_dir.openFile(io, entry.path, .{});
    defer file.close(io);

    var in_buf: [4096]u8 = undefined;
    var in_reader = file.reader(io, &in_buf);
    while (try in_reader.interface.takeDelimiter('\n')) |line| {
        var field_storage: [3][]const u8 = undefined;
        const fields = parse.fieldsBounded(line, &field_storage) catch |err| switch (err) {
            error.TooManyFields => return error.InvalidCodepointPropertyLine,
        };

        if (fields.len == 0) continue;
        if (fields.len < 2) return error.InvalidCodepointPropertyLine;

        const range = try parse.parseCodepointRange(fields[0]);
        const raw_property = entry.property orelse fields[1];
        const canonical_property = aliases.canonicalProperty(raw_property) orelse raw_property;
        const property = entry.namespace orelse canonical_property;
        const raw_value = if (entry.property != null)
            fields[1]
        else if (fields.len == 3)
            fields[2]
        else
            canonical_property;
        const value = aliases.canonicalValue(canonical_property, raw_value) orelse raw_value;

        try db.addRange(property, value, range);
    }
}

fn readScriptExtensionsFile(
    io: std.Io,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *const Aliases,
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
        var field_storage: [2][]const u8 = undefined;
        const fields = parse.fieldsBounded(line, &field_storage) catch |err| switch (err) {
            error.TooManyFields => return error.InvalidScriptExtensionsLine,
        };

        if (fields.len == 0) continue;
        if (fields.len != 2) return error.InvalidScriptExtensionsLine;

        const range = try parse.parseCodepointRange(fields[0]);
        var script_it = std.mem.tokenizeAny(u8, fields[1], " \t");
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

fn addGeneralCategoryAggregates(allocator: std.mem.Allocator, db: *Db, aliases: *const Aliases) !void {
    const group = db.property("GeneralCategory") orelse return;
    for (general_category_aggregates) |aggregate| {
        const target = aliases.canonicalValue("gc", aggregate.target) orelse aggregate.target;
        if (group.value(target) != null) continue;

        var aggregate_ranges: std.ArrayList(parse.Range) = .empty;
        defer aggregate_ranges.deinit(allocator);

        for (aggregate.sources) |source_alias| {
            const source = aliases.canonicalValue("gc", source_alias) orelse source_alias;
            const source_value = group.value(source) orelse return error.MissingGeneralCategoryAggregateSource;
            try aggregate_ranges.appendSlice(allocator, source_value.ranges.items);
        }

        if (aggregate_ranges.items.len == 0) return error.InvalidGeneralCategoryAggregate;
        try db.addRanges("GeneralCategory", target, aggregate_ranges.items);
    }
}

const GeneralCategoryAggregate = struct {
    target: []const u8,
    sources: []const []const u8,
};

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

fn makeFixtureAliases(allocator: std.mem.Allocator) !Aliases {
    var aliases = Aliases.init(allocator);
    errdefer aliases.deinit();

    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyLine("gc ; General_Category");
    try aliases.loadPropertyLine("sc ; Script");
    try aliases.loadPropertyLine("scx ; Script_Extensions");
    try aliases.loadPropertyValueLine("blk ; Basic_Latin ; Basic Latin");
    try aliases.loadPropertyValueLine("sc ; Latn ; Latin");
    try aliases.loadPropertyValueLine("sc ; Grek ; Greek");
    try aliases.loadPropertyValueLine("sc ; Cyrl ; Cyrillic");
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

    return aliases;
}

test "runJob emits one simple property namespace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Blocks.txt",
        .data =
        \\0041; Basic Latin
        \\
        ,
    });
    try tmp.dir.createDirPath(testing.io, "out");
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);

    var aliases = try makeFixtureAliases(testing.allocator);
    defer aliases.deinit();

    const stats = try runJob(testing.io, testing.allocator, tmp.dir, out, &aliases, .{
        .kind = .namespace,
        .namespace = "Blocks",
        .entries = &.{.{ .path = "Blocks.txt", .kind = .codepoint_property, .property = "blk", .namespace = "Blocks" }},
    }, .{});
    defer stats.deinit();

    try testing.expectEqual(@as(usize, 1), stats.groups.len);
    try testing.expectEqualStrings("Blocks", stats.groups[0].name);
    var file = try out.openFile(testing.io, "sets/blocks/Basic_Latin.zig", .{});
    file.close(testing.io);
}

test "runJob emits core properties from merged entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "PropList.txt",
        .data =
        \\0009; White_Space
        \\
        ,
    });
    try tmp.dir.createDirPath(testing.io, "emoji");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "emoji/emoji-data.txt",
        .data =
        \\0023; Emoji
        \\
        ,
    });
    try tmp.dir.createDirPath(testing.io, "out");
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);

    var aliases = try makeFixtureAliases(testing.allocator);
    defer aliases.deinit();

    const stats = try runJob(testing.io, testing.allocator, tmp.dir, out, &aliases, .{
        .kind = .core_properties,
        .namespace = "CoreProperties",
        .entries = &.{
            .{ .path = "PropList.txt", .kind = .codepoint_property, .namespace = "CoreProperties" },
            .{ .path = "emoji/emoji-data.txt", .kind = .codepoint_property, .namespace = "CoreProperties" },
        },
    }, .{});
    defer stats.deinit();

    try testing.expectEqual(@as(usize, 1), stats.groups.len);
    try testing.expectEqual(@as(usize, 2), stats.groups[0].values.len);
    var file = try out.openFile(testing.io, "sets/props/Emoji.zig", .{});
    file.close(testing.io);
}

test "runJob emits general category aggregates locally" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "extracted");
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(testing.allocator);
    inline for (.{
        "Cc", "Cf", "Cn", "Co", "Cs",
        "Ll", "Lm", "Lo", "Lt", "Lu",
        "Mc", "Me", "Mn", "Nd", "Nl",
        "No", "Pc", "Pd", "Pe", "Pf",
        "Pi", "Po", "Ps", "Sc", "Sk",
        "Sm", "So", "Zl", "Zp", "Zs",
    }, 0..) |short, idx| {
        const line = try std.fmt.allocPrint(testing.allocator, "{X:0>4}; {s}\n", .{ 0x100 + idx, short });
        defer testing.allocator.free(line);
        try data.appendSlice(testing.allocator, line);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "extracted/DerivedGeneralCategory.txt", .data = data.items });
    try tmp.dir.createDirPath(testing.io, "out");
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);

    var aliases = try makeFixtureAliases(testing.allocator);
    defer aliases.deinit();

    const stats = try runJob(testing.io, testing.allocator, tmp.dir, out, &aliases, .{
        .kind = .general_category,
        .namespace = "GeneralCategory",
        .entries = &.{.{ .path = "extracted/DerivedGeneralCategory.txt", .kind = .codepoint_property, .property = "gc", .namespace = "GeneralCategory" }},
    }, .{});
    defer stats.deinit();

    try testing.expectEqual(@as(usize, 38), stats.groups[0].values.len);
    var file = try out.openFile(testing.io, "sets/gencat/Letter.zig", .{});
    file.close(testing.io);
}

test "runJob emits scripts bundle with script extension inheritance" {
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
        \\
        ,
    });
    try tmp.dir.createDirPath(testing.io, "out");
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);

    var aliases = try makeFixtureAliases(testing.allocator);
    defer aliases.deinit();

    const stats = try runJob(testing.io, testing.allocator, tmp.dir, out, &aliases, .{
        .kind = .scripts_bundle,
        .namespace = "Scripts",
        .entries = &.{
            .{ .path = "Scripts.txt", .kind = .codepoint_property, .property = "sc", .namespace = "Scripts" },
            .{ .path = "ScriptExtensions.txt", .kind = .script_extensions, .property = "scx", .namespace = "ScriptsExtended" },
        },
    }, .{});
    defer stats.deinit();

    try testing.expectEqual(@as(usize, 2), stats.groups.len);
    var file = try out.openFile(testing.io, "sets/scripts_ext/Cyrillic.zig", .{});
    file.close(testing.io);
}
