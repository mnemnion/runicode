const std = @import("std");
const escString = @import("ezcaper").escStringExactQuoted;
const testing = std.testing;
const unicoder = @import("unicoder");

const Aliases = @import("aliases.zig").Aliases;
const parse = @import("parse.zig");
const RuneSet = @import("runeset").RuneSet;

pub const GeneratedKinds = struct {
    sets: bool = true,
    codepoints: bool = true,
    strings: bool = true,
    names: bool = true,

    pub fn any(kinds: GeneratedKinds) bool {
        return kinds.sets or kinds.codepoints or kinds.strings;
    }
};

/// Filesystem handles and root filenames used by the emitter.
pub const OutputDir = struct {
    /// Caller-owned I/O context threaded through every std.Io operation.
    io: std.Io,

    /// Already-open output directory; emission should not decide where it lives.
    dir: std.Io.Dir,

    /// Generated data views selected by build options.
    kinds: GeneratedKinds = .{},

    /// Top-level module imported by package users.
    runicode_path: []const u8 = "runicode.zig",

    /// Root file which imports every generated RuneSet group.
    sets_path: []const u8 = "sets.zig",

    /// Root file which imports every generated codepoint group.
    codepoints_path: []const u8 = "codepoints.zig",

    /// Root file which imports every generated WTF-8 string group.
    strs_path: []const u8 = "strs.zig",

    /// Root file containing property-value enum types.
    enums_path: []const u8 = "enums.zig",

    /// Root file which imports property lookup maps.
    maps_path: []const u8 = "maps.zig",
};

pub const GroupMeta = struct {
    name: []const u8,
    values: []const []const u8,
};

pub fn freeGroupMeta(allocator: std.mem.Allocator, groups: []const GroupMeta) void {
    for (groups) |group| {
        allocator.free(group.name);
        for (group.values) |value| allocator.free(value);
        allocator.free(group.values);
    }
    allocator.free(groups);
}

/// Writes all generated source files from the loaded UCD database.
pub fn emitRoots(allocator: std.mem.Allocator, dir: OutputDir, db: anytype, aliases: *const Aliases) !void {
    const groups = try emitGroups(allocator, dir, db, aliases);
    defer freeGroupMeta(allocator, groups);
    try emitRootIndexes(allocator, dir, groups, aliases);
}

/// Writes per-group generated files and returns metadata for the root pass.
pub fn emitGroups(allocator: std.mem.Allocator, dir: OutputDir, db: anytype, aliases: *const Aliases) ![]GroupMeta {
    return emitGroupsOwned(allocator, allocator, dir, db, aliases);
}

/// Writes per-group files with scratch allocation separated from returned
/// metadata ownership.
pub fn emitGroupsOwned(
    scratch_allocator: std.mem.Allocator,
    metadata_allocator: std.mem.Allocator,
    dir: OutputDir,
    db: anytype,
    aliases: *const Aliases,
) ![]GroupMeta {
    const group_names = try sortedGroupNames(scratch_allocator, db);
    defer scratch_allocator.free(group_names);

    const groups = try collectGroupMeta(metadata_allocator, group_names, db);
    errdefer freeGroupMeta(metadata_allocator, groups);

    try writeDataGroupFiles(scratch_allocator, dir, group_names, db, aliases);

    return groups;
}

//
/// Writes only root index files from precomputed group metadata.
pub fn emitRootIndexes(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    groups: []const GroupMeta,
    aliases: *const Aliases,
) !void {
    const sorted_groups = try allocator.dupe(GroupMeta, groups);
    defer allocator.free(sorted_groups);
    std.mem.sort(GroupMeta, sorted_groups, {}, groupMetaLessThan);

    try writeDataRootFiles(allocator, dir, sorted_groups, aliases);
    if (dir.kinds.any()) {
        try writeRootFile(dir, dir.enums_path, writeEnumsRoot, .{ allocator, sorted_groups, aliases });
    }
    if (dir.kinds.any()) {
        try writeMapsRootFile(allocator, dir, sorted_groups, aliases);
    }
    try writeRootFile(dir, dir.runicode_path, writeRunicodeRoot, .{dir.kinds});
}

fn collectGroupMeta(allocator: std.mem.Allocator, group_names: []const []const u8, db: anytype) ![]GroupMeta {
    const groups = try allocator.alloc(GroupMeta, group_names.len);
    var group_count: usize = 0;
    errdefer {
        for (groups[0..group_count]) |group| {
            allocator.free(group.name);
            for (group.values) |value| allocator.free(value);
            allocator.free(group.values);
        }
        allocator.free(groups);
    }

    for (group_names, groups) |group_name, *meta| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        const name = try allocator.dupe(u8, group_name);
        errdefer allocator.free(name);

        const values = try allocator.alloc([]const u8, value_names.len);
        var value_count: usize = 0;
        errdefer {
            for (values[0..value_count]) |value| allocator.free(value);
            allocator.free(values);
        }

        for (value_names, values) |value_name, *value| {
            value.* = try allocator.dupe(u8, value_name);
            value_count += 1;
        }

        meta.* = .{
            .name = name,
            .values = values,
        };
        group_count += 1;
    }

    return groups;
}

/// Writes the three generated data trees: sets, codepoints, and strings.
fn writeDataGroupFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: anytype,
    aliases: *const Aliases,
) !void {
    if (dir.kinds.sets) {
        try writeSetsGroupFiles(allocator, dir, group_names, db, aliases);
        try writeSupremumSetFile(allocator, dir, db);
    }
    if (dir.kinds.codepoints) {
        try writeCodepointsGroupFiles(allocator, dir, group_names, db, aliases);
    }
    if (dir.kinds.strings) {
        try writeStrsGroupFiles(allocator, dir, group_names, db, aliases);
    }
}

fn writeDataRootFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    groups: []const GroupMeta,
    aliases: *const Aliases,
) !void {
    if (dir.kinds.sets) {
        try writeDataRootFile(allocator, dir, dir.sets_path, "sets", groups, aliases);
    }
    if (dir.kinds.codepoints) {
        try writeDataRootFile(allocator, dir, dir.codepoints_path, "codepoints", groups, aliases);
    }
    if (dir.kinds.strings) {
        try writeDataRootFile(allocator, dir, dir.strs_path, "strs", groups, aliases);
    }
}

fn writeDataRootFile(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    path: []const u8,
    prefix: []const u8,
    groups: []const GroupMeta,
    aliases: *const Aliases,
) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    try writer.writeAll(header_txt);
    for (groups) |group| {
        const group_path = try semanticGroupFilePath(allocator, prefix, group.name);
        defer allocator.free(group_path);
        try writer.print("pub const {f} = @import(\"{s}\");\n", .{ identifier(group.name), group_path });
    }
    if (std.mem.eql(u8, prefix, "sets") and hasGroup(groups, "GeneralCategory")) {
        try writer.writeAll("pub const Supremum = @import(\"sets/Supremum.zig\").Supremum;\n");
    }
    try writeRootGroupAliases(allocator, writer, groups, aliases, "");
    try writer.flush();
}

/// Opens a root file, calls its writer callback, and flushes the buffered writer.
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

/// Writes strs.zig, one strs/<group>.zig file per property group, and one
/// strs/<group>/<value>.zig file per property value.
fn writeStrsGroupFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: anytype,
    aliases: *const Aliases,
) !void {
    try dir.dir.createDirPath(dir.io, "strs");

    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        const group_dir = try semanticGroupDir(allocator, "strs", group_name);
        defer allocator.free(group_dir);
        try dir.dir.createDirPath(dir.io, group_dir);

        const group_path = try semanticGroupFilePath(allocator, "strs", group_name);
        defer allocator.free(group_path);

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
            try writeStrsValueFile(allocator, dir, value_path, decl_name, value.rune_set.?);
            try group_out.print("pub const {f} = @import(\"{s}\").{f};\n", .{ identifier(decl_name), import_path, identifier(decl_name) });
        }
        try writeGroupValueAliases(allocator, group_out, group_name, value_names, aliases);
        try group_out.flush();
    }
}

/// Writes one string leaf file. RuneSet collapses duplicate or overlapping
/// ranges before ezcaper quotes the resulting WTF-8 bytes.
fn writeStrsValueFile(allocator: std.mem.Allocator, dir: OutputDir, path: []const u8, decl_name: []const u8, rune_set: RuneSet) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    const normalized = try stringFromRuneSet(allocator, rune_set);
    defer allocator.free(normalized);

    try writer.writeAll(header_txt);
    try writer.print("pub const {f} = {f};\n", .{ identifier(decl_name), escString(normalized) });
    try writer.flush();
}

/// Writes codepoints.zig, group imports, and one `[N]u21` leaf per value.
/// This is mostly the same loop as `writeStrsFiles` and should probably share
/// structure once the generated layout settles.
fn writeCodepointsGroupFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: anytype,
    aliases: *const Aliases,
) !void {
    try dir.dir.createDirPath(dir.io, "codepoints");

    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        const group_dir = try semanticGroupDir(allocator, "codepoints", group_name);
        defer allocator.free(group_dir);
        try dir.dir.createDirPath(dir.io, group_dir);

        const group_path = try semanticGroupFilePath(allocator, "codepoints", group_name);
        defer allocator.free(group_path);

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
            try writeCodepointsValueFile(dir, value_path, decl_name, value.rune_set.?);
            try group_out.print("pub const {f} = @import(\"{s}\").{f};\n", .{ identifier(decl_name), import_path, identifier(decl_name) });
        }
        try writeGroupValueAliases(allocator, group_out, group_name, value_names, aliases);
        try group_out.flush();
    }
}

/// Writes one codepoint leaf. RuneSet iteration gives the final sorted,
/// deduplicated order.
fn writeCodepointsValueFile(dir: OutputDir, path: []const u8, decl_name: []const u8, rune_set: RuneSet) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    try writer.writeAll(header_txt);
    try writer.print("pub const {f}: [{d}]u21 = .{{ ", .{ identifier(decl_name), rune_set.runeCount() });
    try writeCodepoints(writer, rune_set);
    try writer.writeAll("};\n");
    try writer.flush();
}

/// Writes sets.zig, group imports, and one serialized RuneSet leaf per value.
fn writeSetsGroupFiles(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    group_names: []const []const u8,
    db: anytype,
    aliases: *const Aliases,
) !void {
    try dir.dir.createDirPath(dir.io, "sets");

    for (group_names) |group_name| {
        const group = db.property(group_name).?;
        const value_names = try sortedValueNames(group.allocator, group);
        defer group.allocator.free(value_names);

        const group_dir = try semanticGroupDir(allocator, "sets", group_name);
        defer allocator.free(group_dir);
        try dir.dir.createDirPath(dir.io, group_dir);

        const group_path = try semanticGroupFilePath(allocator, "sets", group_name);
        defer allocator.free(group_path);

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
            try writeSetsValueFile(dir, value_path, decl_name, value.rune_set.?);
            try group_out.print("pub const {f} = @import(\"{s}\").{f};\n", .{ identifier(decl_name), import_path, identifier(decl_name) });
        }
        try writeGroupValueAliases(allocator, group_out, group_name, value_names, aliases);
        try group_out.flush();
    }
}

/// Writes one RuneSet leaf using runeset's serializer.
fn writeSetsValueFile(dir: OutputDir, path: []const u8, decl_name: []const u8, rune_set: RuneSet) !void {
    var file = try dir.dir.createFile(dir.io, path, .{ .lock = .exclusive });
    defer file.close(dir.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(dir.io, &buf);
    const writer = &file_writer.interface;

    try writer.writeAll(header_txt);
    try writer.writeAll("const RuneSet = @import(\"runeset\").RuneSet;\n\n");
    try writer.print("/// Length: {d} words.\n", .{rune_set.body.len});
    try rune_set.serialize(writer, .public, decl_name);
    try writer.flush();
}

fn writeSupremumSetFile(allocator: std.mem.Allocator, dir: OutputDir, db: anytype) !void {
    const group = db.property("GeneralCategory") orelse return;

    var ranges: std.ArrayList(parse.Range) = .empty;
    defer ranges.deinit(allocator);

    var it = group.values.iterator();
    while (it.next()) |entry| {
        if (isSupremumExcludedCategory(entry.key_ptr.*)) continue;
        try ranges.appendSlice(allocator, entry.value_ptr.ranges.items);
    }
    if (ranges.items.len == 0) return;

    const supremum = try createRuneSetFromRanges(ranges.items, allocator);
    defer supremum.deinit(allocator);
    try writeSetsValueFile(dir, "sets/Supremum.zig", "Supremum", supremum);
}

/// Adds `pub const Alias = Canonical;` declarations to a group root. `seen_decls`
/// prevents duplicate aliases after UCD names are converted to Zig names.
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

/// Writes one enum per property group into enums.zig.
fn writeEnumsRoot(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    groups: []const GroupMeta,
    aliases: *const Aliases,
) !void {
    try writer.writeAll(header_txt);
    for (groups) |group| {
        try writeEnumType(allocator, writer, group.name, group.values);
    }
    try writeRootGroupAliases(allocator, writer, groups, aliases, "");
}

fn writeEnumType(allocator: std.mem.Allocator, writer: *std.Io.Writer, group_name: []const u8, value_names: []const []const u8) !void {
    try writer.print("pub const {f} = enum {{\n", .{identifier(group_name)});
    for (value_names) |value_name| {
        const decl_name = try declName(allocator, value_name);
        defer allocator.free(decl_name);
        try writer.print("    {f},\n", .{identifier(decl_name)});
    }
    try writer.writeAll("};\n\n");
}

/// Writes runicode.zig, the public import root for generated data.
fn writeRunicodeRoot(writer: *std.Io.Writer, kinds: GeneratedKinds) !void {
    try writer.writeAll(header_txt);
    if (kinds.sets) {
        try writer.writeAll(
            \\/// Unicode property data as RuneSet values.
            \\pub const sets = @import("sets.zig");
            \\
        );
    }
    if (kinds.codepoints) {
        try writer.writeAll(
            \\/// Unicode property data as sorted codepoint slices.
            \\pub const codepoints = @import("codepoints.zig");
            \\
        );
    }
    if (kinds.names) {
        try writer.writeAll(
            \\/// Unicode character names and formal aliases as a loose-matching codepoint map.
            \\pub const names = @import("names.zig");
            \\pub const CharacterNames = names.CharacterNames;
            \\pub const NamedCodepoints = CharacterNames;
            \\
        );
    }
    if (kinds.strings) {
        try writer.writeAll(
            \\/// Unicode property data as UTF-8 strings.
            \\pub const strs = @import("strs.zig");
            \\pub const strings = strs;
            \\
        );
    }
    if (kinds.any()) {
        try writer.writeAll(
            \\/// Unicode property enum types.
            \\pub const enums = @import("enums.zig");
            \\
        );
    }
    if (kinds.any()) {
        try writer.writeAll(
            \\/// Loose-matching maps for Unicode property namespaces.
            \\pub const maps = @import("maps.zig");
            \\
        );
        if (kinds.sets) {
            try writer.writeAll(
                \\/// Loose-matching map over generated Unicode property set maps.
                \\pub const NamedSetMaps = maps.NamedSetMaps;
                \\
            );
        }
        if (kinds.codepoints) {
            try writer.writeAll(
                \\/// Loose-matching map over generated Unicode property codepoint maps.
                \\pub const NamedCodepointMaps = maps.NamedCodepointMaps;
                \\
            );
        }
        if (kinds.strings) {
            try writer.writeAll(
                \\/// Loose-matching map over generated Unicode property string maps.
                \\pub const NamedStringMaps = maps.NamedStringMaps;
                \\
            );
        }
    }
    try writer.writeAll(
        \\/// Compile-time constructor for loose-matching property maps.
        \\pub const NamedMap = @import("ucd-tools").NamedMap;
        \\
        \\/// Backwards-readable plural alias for the loose-matching map constructor.
        \\pub const NamedMaps = NamedMap;
        \\
    );
}

/// Writes maps.zig from group metadata.
fn writeMapsRootFile(
    allocator: std.mem.Allocator,
    dir: OutputDir,
    groups: []const GroupMeta,
    aliases: *const Aliases,
) !void {
    var root_file = try dir.dir.createFile(dir.io, dir.maps_path, .{ .lock = .exclusive });
    defer root_file.close(dir.io);
    var root_buf: [4096]u8 = undefined;
    var root_writer = root_file.writer(dir.io, &root_buf);
    const writer = &root_writer.interface;

    try writer.writeAll(header_txt);
    try writer.writeAll("const ucd_tools = @import(\"ucd-tools\");\n\n");
    if (dir.kinds.sets) {
        try writeKindMapSource(allocator, writer, groups, aliases, "sets", "sets", "NamedSetMaps");
    }
    if (dir.kinds.codepoints) {
        try writeKindMapSource(allocator, writer, groups, aliases, "codepoints", "codepoints", "NamedCodepointMaps");
    }
    if (dir.kinds.strings) {
        try writeKindMapSource(allocator, writer, groups, aliases, "strings", "strs", "NamedStringMaps");
        try writer.writeAll("pub const strs = strings;\n");
    }
    try writer.flush();
}

fn writeKindMapSource(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    groups: []const GroupMeta,
    aliases: *const Aliases,
    namespace_name: []const u8,
    import_prefix: []const u8,
    named_maps_name: []const u8,
) !void {
    try writer.print("pub const {f} = struct {{\n", .{identifier(namespace_name)});
    for (groups) |group| {
        const group_path = try semanticGroupFilePath(allocator, import_prefix, group.name);
        defer allocator.free(group_path);
        try writer.print("    pub const {f} = ucd_tools.NamedMap(@import(\"{s}\"));\n", .{ identifier(group.name), group_path });
    }
    try writeRootGroupAliases(allocator, writer, groups, aliases, "    ");
    try writer.writeAll("};\n\n");
    try writer.print("pub const {f} = ucd_tools.NamedMap({f});\n\n", .{
        identifier(named_maps_name),
        identifier(namespace_name),
    });
}

fn writeRootGroupAliases(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    groups: []const GroupMeta,
    aliases: *const Aliases,
    indent: []const u8,
) !void {
    var seen_decls: std.StringHashMapUnmanaged(void) = .empty;
    defer freeSeenMatches(allocator, &seen_decls);

    for (groups) |group| {
        const group_decl = try allocator.dupe(u8, group.name);
        errdefer allocator.free(group_decl);
        const result = try seen_decls.getOrPut(allocator, group_decl);
        if (result.found_existing) allocator.free(group_decl);
    }

    for (groups) |group| {
        const group_aliases = try rootAliasesForGroup(allocator, aliases, group.name);
        defer freeStringList(allocator, group_aliases);

        for (group_aliases) |alias| {
            const alias_decl = try declName(allocator, alias);
            errdefer allocator.free(alias_decl);
            if (std.mem.eql(u8, alias_decl, group.name)) {
                allocator.free(alias_decl);
                continue;
            }

            const result = try seen_decls.getOrPut(allocator, alias_decl);
            if (result.found_existing) {
                allocator.free(alias_decl);
                continue;
            }
            try writer.print("{s}pub const {f} = {f};\n", .{ indent, identifier(alias_decl), identifier(group.name) });
        }
    }
}

fn rootAliasesForGroup(
    allocator: std.mem.Allocator,
    aliases: *const Aliases,
    group_name: []const u8,
) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    const alias_group = rootAliasGroup(group_name) orelse return try allocator.alloc([]const u8, 0);

    if (alias_group.property) |property| {
        const canonical_property = aliases.canonicalProperty(property) orelse property;
        var property_it = aliases.properties.iterator();
        while (property_it.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*, canonical_property)) continue;
            try appendUniqueString(allocator, &result, entry.key_ptr.*);
        }
    }

    for (alias_group.extra_aliases) |alias| try appendUniqueString(allocator, &result, alias);

    std.mem.sort([]const u8, result.items, {}, ltString);
    return try result.toOwnedSlice(allocator);
}

fn appendUniqueString(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, value)) return;
    }
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try list.append(allocator, owned_value);
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn rootAliasGroup(group_name: []const u8) ?RootAliasGroup {
    for (root_alias_groups) |alias_group| {
        if (std.mem.eql(u8, alias_group.group, group_name)) return alias_group;
    }
    return null;
}

fn hasGroup(groups: []const GroupMeta, name: []const u8) bool {
    for (groups) |group| {
        if (std.mem.eql(u8, group.name, name)) return true;
    }
    return false;
}

/// Frees copied keys stored in temporary string maps.
fn freeSeenMatches(allocator: std.mem.Allocator, seen_matches: *std.StringHashMapUnmanaged(void)) void {
    var it = seen_matches.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    seen_matches.deinit(allocator);
}

/// Writes each RuneSet item as a `0x...` u21 literal.
fn writeCodepoints(writer: *std.Io.Writer, rune_set: RuneSet) !void {
    var iter = rune_set.iterateRunes();
    while (iter.next()) |rune| {
        const codepoint = unicoder.wtf8.valid.decode(rune);
        try writer.print("0x{X}, ", .{codepoint});
    }
}

/// Copies RuneSet's sorted WTF-8 slices into one string buffer.
fn stringFromRuneSet(allocator: std.mem.Allocator, rune_set: RuneSet) ![]u8 {
    var str: std.ArrayList(u8) = .empty;
    errdefer str.deinit(allocator);

    var iter = rune_set.iterateRunes();
    while (iter.next()) |rune| {
        try str.appendSlice(allocator, rune);
    }
    return try str.toOwnedSlice(allocator);
}

/// Returns `<prefix>/<group>/<value>.zig`.
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

/// Returns `<prefix>/<group>.zig`.
fn semanticGroupFilePath(allocator: std.mem.Allocator, prefix: []const u8, group_name: []const u8) ![]const u8 {
    const group_dir = try semanticGroupDir(allocator, prefix, group_name);
    defer allocator.free(group_dir);
    return try std.fmt.allocPrint(allocator, "{s}.zig", .{group_dir});
}

/// Creates the parent directory for `path`, if it has one.
fn createParentDirPath(dir: OutputDir, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try dir.dir.createDirPath(dir.io, parent);
}

/// Returns the path a group file should use to import one of its value files.
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

/// Thin alias for `pathName`; exists only because declaration names and path
/// names might diverge later. Delete it if they do not.
fn declName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return pathName(allocator, name);
}

/// Returns `<prefix>/<group-dir>`, using legacy short directories when known.
fn semanticGroupDir(allocator: std.mem.Allocator, prefix: []const u8, group_name: []const u8) ![]const u8 {
    const suffix = semanticGroupSuffix(group_name);
    if (suffix) |literal| {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, literal });
    }

    const group_path = try pathName(allocator, group_name);
    defer allocator.free(group_path);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, group_path });
}

/// Legacy directory spellings for generated property groups.
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

/// Returns the PropertyValueAliases namespace for a generated group.
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

/// Converts a UCD name to an ASCII fragment usable in paths and identifiers.
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

/// Returns DB group names in deterministic order.
fn sortedGroupNames(allocator: std.mem.Allocator, db: anytype) ![][]const u8 {
    var names = try allocator.alloc([]const u8, db.groups.count());
    var it = db.groups.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) names[idx] = entry.key_ptr.*;
    std.mem.sort([]const u8, names, {}, ltString);
    return names;
}

/// Returns property value names in deterministic order.
fn sortedValueNames(allocator: std.mem.Allocator, group: anytype) ![][]const u8 {
    var names = try allocator.alloc([]const u8, group.values.count());
    var it = group.values.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) names[idx] = entry.key_ptr.*;
    std.mem.sort([]const u8, names, {}, ltString);
    return names;
}

/// Lexical ordering predicate for generated-file stability.
fn ltString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn groupMetaLessThan(_: void, left: GroupMeta, right: GroupMeta) bool {
    return ltString({}, left.name, right.name);
}

const RootAliasGroup = struct {
    group: []const u8,
    property: ?[]const u8 = null,
    extra_aliases: []const []const u8 = &.{},
};

const root_alias_groups = [_]RootAliasGroup{
    .{ .group = "Age", .property = "age" },
    .{ .group = "BidiClass", .property = "bc" },
    .{ .group = "Blocks", .property = "blk" },
    .{ .group = "CombiningClass", .property = "ccc" },
    .{ .group = "DecompositionType", .property = "dt" },
    .{ .group = "EastAsianWidth", .property = "ea" },
    .{ .group = "GeneralCategory", .property = "gc" },
    .{
        .group = "GraphemeBreak",
        .property = "GCB",
        .extra_aliases = &.{
            "gcb",
            "gbp",
            "Grapheme_Break_Property",
            "GraphemeBreakProperty",
        },
    },
    .{ .group = "HangulSyllableType", .property = "hst" },
    .{ .group = "IndicPositionalCategory", .property = "InPC" },
    .{ .group = "IndicSyllabicCategory", .property = "InSC" },
    .{ .group = "JoiningGroup", .property = "jg" },
    .{ .group = "JoiningType", .property = "jt" },
    .{ .group = "LineBreak", .property = "lb" },
    .{ .group = "NumericType", .property = "nt" },
    .{ .group = "Scripts", .property = "sc" },
    .{
        .group = "ScriptsExtended",
        .property = "scx",
        .extra_aliases = &.{
            "ScriptExtensions",
        },
    },
    .{ .group = "SentenceBreak", .property = "SB" },
    .{ .group = "VerticalOrientation", .property = "vo" },
    .{ .group = "WordBreak", .property = "WB" },
};

fn isSupremumExcludedCategory(value_name: []const u8) bool {
    inline for (supremum_excluded_categories) |excluded| {
        if (std.mem.eql(u8, value_name, excluded)) return true;
    }
    return false;
}

const supremum_excluded_categories = [_][]const u8{
    "Cn",
    "Co",
    "Cs",
    "Unassigned",
    "Private_Use",
    "Surrogate",
    "C",
    "L",
    "LC",
    "M",
    "N",
    "P",
    "S",
    "Z",
    "Other",
    "Letter",
    "Cased_Letter",
    "Mark",
    "Number",
    "Punctuation",
    "Symbol",
    "Separator",
};

/// Escapes bytes for Zig's `@"..."` identifier syntax.
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

/// Wraps a name for `{f}` formatting as a Zig identifier.
fn identifier(name: []const u8) Identifier {
    return .{ .name = name };
}

/// Formats a string as either a bare identifier or `@"..."`.
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

/// Returns whether Zig accepts `name` as an unquoted identifier.
fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return std.zig.Token.getKeyword(name) == null;
}

/// Common warning header for every generated file.
const header_txt =
    \\//! Generated source!
    \\//! Do not modify!
    \\
    \\
;

const Db = struct {
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

    fn property(db: *Db, name: []const u8) ?*PropertyGroup {
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

const PropertyGroup = struct {
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

    fn value(group: *PropertyGroup, name: []const u8) ?*PropertyValue {
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

const PropertyValue = struct {
    ranges: std.ArrayList(parse.Range) = .empty,
    rune_set: ?RuneSet = null,

    fn deinit(value: *PropertyValue, allocator: std.mem.Allocator) void {
        value.ranges.deinit(allocator);
        if (value.rune_set) |set| set.deinit(allocator);
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

// Covers the generated root graph and alias forwarding without needing the full
// UCD corpus.
test "emitRoots writes generated property roots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x42 });
    try db.addRange("GeneralCategory", "Cn", .{ .first = 0x43, .last = 0x43 });
    try db.addRange("GeneralCategory", "Co", .{ .first = 0x44, .last = 0x44 });
    try db.addRange("GeneralCategory", "Cs", .{ .first = 0x45, .last = 0x45 });
    try db.addRange("GraphemeBreak", "Control", .{ .first = 0x00, .last = 0x01 });
    try db.addRange("Age", "V1_1", .{ .first = 0x41, .last = 0x41 });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("gc ; General_Category");
    try aliases.loadPropertyLine("GCB ; Grapheme_Cluster_Break");
    try aliases.loadPropertyValueLine("gc ; Lu ; Uppercase_Letter");
    try aliases.loadPropertyValueLine("GCB ; CN ; Control");
    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyValueLine("blk ; ASCII ; Basic_Latin");

    try db.finalizeRuneSets();
    try emitRoots(testing.allocator, .{ .io = testing.io, .dir = tmp.dir }, &db, &aliases);

    inline for (.{ "runicode.zig", "sets.zig", "codepoints.zig", "strs.zig", "enums.zig", "maps.zig" }) |path| {
        var file = try tmp.dir.openFile(testing.io, path, .{});
        file.close(testing.io);
    }

    const runicode = try tmp.dir.readFileAlloc(testing.io, "runicode.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(runicode);
    const sets = try tmp.dir.readFileAlloc(testing.io, "sets.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(sets);
    const supremum = try tmp.dir.readFileAlloc(testing.io, "sets/Supremum.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(supremum);
    const codepoints = try tmp.dir.readFileAlloc(testing.io, "codepoints.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(codepoints);
    const strs = try tmp.dir.readFileAlloc(testing.io, "strs.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(strs);
    const enums = try tmp.dir.readFileAlloc(testing.io, "enums.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(enums);
    const maps = try tmp.dir.readFileAlloc(testing.io, "maps.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(maps);

    try testing.expect(std.mem.indexOf(u8, runicode, "pub const sets = @import(\"sets.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const names = @import(\"names.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const CharacterNames = names.CharacterNames;") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const NamedCodepoints = CharacterNames;") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const maps = @import(\"maps.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const NamedSetMaps = maps.NamedSetMaps;") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const NamedCodepointMaps = maps.NamedCodepointMaps;") != null);
    try testing.expect(std.mem.indexOf(u8, runicode, "pub const NamedStringMaps = maps.NamedStringMaps;") != null);
    try testing.expect(std.mem.indexOf(u8, sets, "pub const gc = GeneralCategory;") != null);
    try testing.expect(std.mem.indexOf(u8, sets, "pub const General_Category = GeneralCategory;") != null);
    try testing.expect(std.mem.indexOf(u8, sets, "pub const GCB = GraphemeBreak;") != null);
    try testing.expect(std.mem.indexOf(u8, sets, "pub const gcb = GraphemeBreak;") != null);
    try testing.expect(std.mem.indexOf(u8, sets, "pub const gbp = GraphemeBreak;") != null);
    try testing.expect(std.mem.indexOf(u8, sets, "pub const Grapheme_Break_Property = GraphemeBreak;") != null);
    try testing.expect(std.mem.indexOf(u8, sets, "pub const Supremum = @import(\"sets/Supremum.zig\").Supremum;") != null);
    try testing.expect(std.mem.indexOf(u8, supremum, "pub const Supremum") != null);
    try testing.expect(std.mem.indexOf(u8, codepoints, "pub const gc = GeneralCategory;") != null);
    try testing.expect(std.mem.indexOf(u8, codepoints, "Supremum") == null);
    try testing.expect(std.mem.indexOf(u8, strs, "pub const GeneralCategory") != null);
    try testing.expect(std.mem.indexOf(u8, strs, "Supremum") == null);
    try testing.expect(std.mem.indexOf(u8, strs, "pub const gbp = GraphemeBreak;") != null);
    try testing.expect(std.mem.indexOf(u8, enums, "pub const gc = GeneralCategory;") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const sets = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const codepoints = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const strings = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const GeneralCategory = ucd_tools.NamedMap(@import(\"sets/gencat.zig\"));") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const GeneralCategory = ucd_tools.NamedMap(@import(\"codepoints/gencat.zig\"));") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const GeneralCategory = ucd_tools.NamedMap(@import(\"strs/gencat.zig\"));") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const gc = GeneralCategory;") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const gbp = GraphemeBreak;") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const NamedSetMaps = ucd_tools.NamedMap(sets);") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const NamedCodepointMaps = ucd_tools.NamedMap(codepoints);") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const NamedStringMaps = ucd_tools.NamedMap(strings);") != null);
    try testing.expect(std.mem.indexOf(u8, maps, "pub const GeneralCategory = @import(\"maps/gencat.zig\");") == null);

    const gencat = try tmp.dir.readFileAlloc(testing.io, "strs/gencat.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(gencat);

    try testing.expect(std.mem.indexOf(u8, gencat, "pub const Lu = @import(\"gencat/Lu.zig\").Lu;") != null);
    try testing.expect(std.mem.indexOf(u8, gencat, "pub const Uppercase_Letter = Lu;") != null);
}

// Covers leaf payloads and historical path spelling for the three data views.
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

    try db.finalizeRuneSets();
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
    const maps_root = try tmp.dir.readFileAlloc(testing.io, "maps.zig", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(maps_root);

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
    try testing.expect(std.mem.indexOf(u8, maps_root, "pub const Blocks = ucd_tools.NamedMap(@import(\"sets/blocks.zig\"));") != null);
    try testing.expect(std.mem.indexOf(u8, maps_root, "pub const Blocks = ucd_tools.NamedMap(@import(\"codepoints/blocks.zig\"));") != null);
}

test "emitGroups and emitRootIndexes split group files from root files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("Blocks", "Basic_Latin", .{ .first = 0x41, .last = 0x41 });

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyValueLine("blk ; ASCII ; Basic_Latin");

    try db.finalizeRuneSets();
    const groups = try emitGroups(testing.allocator, .{ .io = testing.io, .dir = tmp.dir }, &db, &aliases);
    defer freeGroupMeta(testing.allocator, groups);

    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("Blocks", groups[0].name);
    try testing.expectEqual(@as(usize, 1), groups[0].values.len);
    try testing.expectEqualStrings("Basic_Latin", groups[0].values[0]);

    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "sets.zig", .{}));
    var group_file = try tmp.dir.openFile(testing.io, "sets/blocks.zig", .{});
    group_file.close(testing.io);

    try emitRootIndexes(testing.allocator, .{ .io = testing.io, .dir = tmp.dir }, groups, &aliases);

    var root_file = try tmp.dir.openFile(testing.io, "sets.zig", .{});
    root_file.close(testing.io);
    const enums = try tmp.dir.readFileAlloc(testing.io, "enums.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(enums);

    try testing.expect(std.mem.indexOf(u8, enums, "pub const Blocks = enum {") != null);
}

test "emitRootIndexes sorts unsorted group metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const groups = [_]GroupMeta{
        .{ .name = "Scripts", .values = &.{} },
        .{ .name = "Blocks", .values = &.{} },
    };

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try emitRootIndexes(testing.allocator, .{ .io = testing.io, .dir = tmp.dir }, &groups, &aliases);

    const sets = try tmp.dir.readFileAlloc(testing.io, "sets.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(sets);

    const blocks_index = std.mem.indexOf(u8, sets, "pub const Blocks").?;
    const scripts_index = std.mem.indexOf(u8, sets, "pub const Scripts").?;
    try testing.expect(blocks_index < scripts_index);
}
