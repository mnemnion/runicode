//! Auxiliary property files generator.
//!
//!

const std = @import("std");

const tools = @import("ucd-tools");
const escString = tools.ezcaper.escStringExactQuoted;

const CodepointMap = tools.CodepointMap;
const Runeset = tools.runeset.RuneSet;
const RuneMap = tools.RuneMap;

const LineIterator = tools.LineIterator;
const StringMap = tools.StringMap;

const AuxProperty = struct {
    namespace: []const u8,
    path: []const u8,
    kind_name: []const u8,
};

const aux_properties = [_]AuxProperty{
    .{
        .namespace = "GraphemeBreak",
        .path = "UCD/auxiliary/GraphemeBreakProperty.txt",
        .kind_name = "GraphemeBreakKind",
    },
    .{
        .namespace = "SentenceBreak",
        .path = "UCD/auxiliary/SentenceBreakProperty.txt",
        .kind_name = "SentenceBreakKind",
    },
    .{
        .namespace = "WordBreak",
        .path = "UCD/auxiliary/WordBreakProperty.txt",
        .kind_name = "WordBreakKind",
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try writeRootIndexes(io);

    const enum_file = try std.Io.Dir.cwd()
        .createFile(io, "src/enums/AuxProperties.zig", .{ .lock = .exclusive });
    defer enum_file.close(io);
    var enum_buf: [4096]u8 = undefined;
    var enum_writer = enum_file.writer(io, &enum_buf);
    const enum_write = &enum_writer.interface;
    try enum_write.writeAll(header_txt);

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout_write = &stdout_writer.interface;

    for (&aux_properties) |aux| {
        var string_map: StringMap = .{ .allocator = allocator };
        var codepoint_map: CodepointMap = .{ .allocator = allocator };
        try readAuxProperty(io, allocator, aux, &string_map, &codepoint_map);

        const sorted_keys = try string_map.sortedKeys();
        var path_list: TextList = TextList.init(allocator);

        try writeStrings(io, allocator, aux, sorted_keys, &string_map, &path_list);
        try writeSets(io, allocator, aux, sorted_keys, &string_map, &path_list);
        try writeCodepoints(io, aux, sorted_keys, &codepoint_map, &path_list);
        try writeEnum(enum_write, aux, sorted_keys);

        try stdout_write.print("{s}: ", .{aux.namespace});
        for (sorted_keys) |key| {
            try stdout_write.print("{s} ", .{key});
        }
        try stdout_write.writeByte('\n');
    }

    try enum_write.flush();
    try stdout_write.flush();
    std.process.cleanExit(io);
}

fn readAuxProperty(
    io: std.Io,
    allocator: std.mem.Allocator,
    aux: AuxProperty,
    string_map: *StringMap,
    codepoint_map: *CodepointMap,
) !void {
    var in_file = try std.Io.Dir.cwd().openFile(io, aux.path, .{});
    defer in_file.close(io);
    var in_buf: [4096]u8 = undefined;
    const in_reader = in_file.reader(io, &in_buf);
    var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
    while (try line_iter.next()) |tok_iter_const| {
        var tok_iter = tok_iter_const;
        const first = tok_iter.next().?;
        const prop_token = tok_iter.next().?.label;
        if (tok_iter.next()) |tok| {
            std.debug.print("Unexpected token in {s}: {any}\n", .{ aux.path, tok });
        }
        const prop = prop_token.value();
        const list = try string_map.get(prop);
        const codepoints = try codepoint_map.get(prop);
        switch (first) {
            .label, .hyphenated, .number, .none, .sequence, .label_set => unreachable,
            .point => |pt| {
                try pt.append(allocator, list);
                try pt.appendCodepoint(allocator, codepoints);
            },
            .range => |r| {
                try r.append(allocator, list);
                try r.appendCodepoints(allocator, codepoints);
            },
        }
    }
}

fn writeRootIndexes(io: std.Io) !void {
    const roots = [_]RootIndex{
        .{ .path = "src/strs/AuxProperties.zig", .prefix = "aux-props" },
        .{ .path = "src/sets/AuxProperties.zig", .prefix = "aux-props" },
        .{ .path = "src/codepoints/AuxProperties.zig", .prefix = "aux-props" },
    };
    for (&roots) |root| {
        const file = try std.Io.Dir.cwd().createFile(io, root.path, .{ .lock = .exclusive });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        const write = &writer.interface;
        try write.writeAll(header_txt);
        for (&aux_properties) |aux| {
            try write.print(
                \\pub const {s} = @import("{s}/{s}.zig");
                \\
                \\
            , .{ aux.namespace, root.prefix, aux.namespace });
        }
        try write.flush();
    }
}

fn writeStrings(
    io: std.Io,
    allocator: std.mem.Allocator,
    aux: AuxProperty,
    sorted_keys: []const []const u8,
    string_map: *StringMap,
    path_list: *TextList,
) !void {
    _ = allocator;
    try std.Io.Dir.cwd().createDirPath(io, try joinedPath(path_list, "src/strs/aux-props/", aux.namespace));
    const main_file = try std.Io.Dir.cwd()
        .createFile(io, try joinedFile(path_list, "src/strs/aux-props/", aux.namespace), .{ .lock = .exclusive });
    defer main_file.close(io);
    var main_buf: [4096]u8 = undefined;
    var main_writer = main_file.writer(io, &main_buf);
    const main_write = &main_writer.interface;
    try main_write.writeAll(header_txt);
    for (sorted_keys) |key| {
        try main_write.print(
            \\pub const {s} = @import("{s}/{s}.zig").{s};
            \\
            \\
        , .{ key, aux.namespace, key, key });
        const str = (try string_map.get(key)).items;
        var str_file = try std.Io.Dir.cwd()
            .createFile(io, try srcPath(path_list, "src/strs/aux-props/", aux.namespace, key), .{ .lock = .exclusive });
        defer str_file.close(io);
        var str_buf: [4096]u8 = undefined;
        var str_writer = str_file.writer(io, &str_buf);
        const str_write = &str_writer.interface;
        try str_write.writeAll(header_txt);
        try str_write.print("pub const {s} = {f};\n", .{ key, escString(str) });
        try str_write.flush();
    }
    try main_write.flush();
}

fn writeSets(
    io: std.Io,
    allocator: std.mem.Allocator,
    aux: AuxProperty,
    sorted_keys: []const []const u8,
    string_map: *StringMap,
    path_list: *TextList,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, try joinedPath(path_list, "src/sets/aux-props/", aux.namespace));

    var rune_map: RuneMap = .empty;
    for (sorted_keys) |key| {
        const this_str = (try string_map.get(key)).items;
        const this_runeset = try Runeset.createFromConstString(this_str, allocator);
        try rune_map.put(allocator, key, this_runeset);
    }

    const main_file = try std.Io.Dir.cwd()
        .createFile(io, try joinedFile(path_list, "src/sets/aux-props/", aux.namespace), .{ .lock = .exclusive });
    defer main_file.close(io);
    var main_buf: [4096]u8 = undefined;
    var main_writer = main_file.writer(io, &main_buf);
    const main_write = &main_writer.interface;
    try main_write.writeAll(header_txt);
    for (sorted_keys) |key| {
        try main_write.print(
            \\pub const {s} = @import("{s}/{s}.zig").{s};
            \\
            \\
        , .{ key, aux.namespace, key, key });
        const rune = rune_map.get(key).?;
        var set_file = try std.Io.Dir.cwd()
            .createFile(io, try srcPath(path_list, "src/sets/aux-props/", aux.namespace, key), .{ .lock = .exclusive });
        defer set_file.close(io);
        var set_buf: [4096]u8 = undefined;
        var set_writer = set_file.writer(io, &set_buf);
        const set_write = &set_writer.interface;
        try set_write.writeAll(header_txt);
        try set_write.writeAll("const RuneSet = @import(\"runeset\").RuneSet;\n\n");
        try set_write.print("// Length: {d}.\n", .{rune.body.len});
        try rune.serialize(set_write, .public, key);
        try set_write.flush();
    }
    try main_write.flush();
}

fn writeCodepoints(
    io: std.Io,
    aux: AuxProperty,
    sorted_keys: []const []const u8,
    codepoint_map: *CodepointMap,
    path_list: *TextList,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, try joinedPath(path_list, "src/codepoints/aux-props/", aux.namespace));
    const main_file = try std.Io.Dir.cwd()
        .createFile(io, try joinedFile(path_list, "src/codepoints/aux-props/", aux.namespace), .{ .lock = .exclusive });
    defer main_file.close(io);
    var main_buf: [4096]u8 = undefined;
    var main_writer = main_file.writer(io, &main_buf);
    const main_write = &main_writer.interface;
    try main_write.writeAll(header_txt);
    for (sorted_keys) |key| {
        try main_write.print(
            \\pub const {s} = @import("{s}/{s}.zig").{s};
            \\
            \\
        , .{ key, aux.namespace, key, key });
        const codepoints = (try codepoint_map.get(key)).items;
        var cp_file = try std.Io.Dir.cwd()
            .createFile(io, try srcPath(path_list, "src/codepoints/aux-props/", aux.namespace, key), .{ .lock = .exclusive });
        defer cp_file.close(io);
        var cp_buf: [4096]u8 = undefined;
        var cp_writer = cp_file.writer(io, &cp_buf);
        const cp_write = &cp_writer.interface;
        try cp_write.writeAll(header_txt);
        try tools.writeCodepointArray(cp_write, key, codepoints);
        try cp_write.flush();
    }
    try main_write.flush();
}

fn writeEnum(write: *std.Io.Writer, aux: AuxProperty, sorted_keys: []const []const u8) !void {
    try write.print("pub const {s} = enum {{\n", .{aux.kind_name});
    for (sorted_keys) |key| {
        try write.print("    {s},\n", .{key});
    }
    try write.writeAll("};\n\n");
}

const RootIndex = struct {
    path: []const u8,
    prefix: []const u8,
};

const header_txt =
    \\//! Generated source!
    \\//! Do not modify!
    \\
    \\
;

fn joinedPath(tl: *TextList, prefix: []const u8, namespace: []const u8) ![]const u8 {
    try tl.appendSlice(prefix);
    try tl.appendSlice(namespace);
    return tl.toOwnedSlice();
}

fn joinedFile(tl: *TextList, prefix: []const u8, namespace: []const u8) ![]const u8 {
    try tl.appendSlice(prefix);
    try tl.appendSlice(namespace);
    try tl.appendSlice(".zig");
    return tl.toOwnedSlice();
}

fn srcPath(tl: *TextList, prefix: []const u8, namespace: []const u8, key: []const u8) ![]const u8 {
    try tl.appendSlice(prefix);
    try tl.appendSlice(namespace);
    try tl.appendSlice("/");
    try tl.appendSlice(key);
    try tl.appendSlice(".zig");
    return tl.toOwnedSlice();
}

const TextList = std.array_list.Managed(u8);
