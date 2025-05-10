//! Blocks files generator
//!
//!

const std = @import("std");

const tools = @import("ucd-tools");
const escString = tools.ezcaper.escStringExact;

const Runeset = tools.runeset.RuneSet;
const RuneMap = tools.RuneMap;

const LineIterator = tools.LineIterator;
const TokenIterator = tools.TokenIterator;
const StringMap = tools.StringMap;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var string_map: StringMap = .{ .allocator = allocator };

    // TODO: Synonyms from PropertyValueAliases

    var in_file = try std.fs.cwd().openFile("UCD/Blocks.txt", .{});
    defer in_file.close();
    var in_buf = std.io.bufferedReader(in_file.reader());
    const in_reader = in_buf.reader();
    var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
    var buf: [128]u8 = undefined;
    while (try line_iter.next()) |tok_iter_const| {
        var tok_iter = tok_iter_const;
        const first = tok_iter.next().?;
        const block_token = tok_iter.next().?;
        std.debug.assert(tok_iter.next() == null);
        var block: []const u8 = undefined;
        _ = &block;
        switch (block_token) {
            .point, .none, .range, .number, .sequence => unreachable,
            .label => |l| block = l.value(),
            .label_set => |ls| block = normalize(&buf, ls.value()),
            .hyphenated => |h| block = normalize(&buf, h.value()),
        }
        const list = try string_map.get(block);
        switch (first) {
            .label, .point, .hyphenated, .none, .number, .sequence, .label_set => unreachable,
            .range => |r| {
                try r.append(allocator, list);
            },
        }
    }
    const sorted_keys = try string_map.sortedKeys();
    var path_list: TextList = TextList.init(allocator);
    // const props_map = try tools.propertyMap(allocator);
    // const gc_map = props_map.get("gc").?;
    // Write strings files
    {
        const main_file = try std.fs.cwd()
            .createFile("src/strs/Blocks.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_write = main_file.writer();
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("blocks/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            // TODO: maybe use .@"" format to supply names as found in Blocks.txt?
            //
            // const other_names = gc_map.get(key).?;
            // switch (other_names) {
            //     .alias => |alias| {
            //         try main_write.print(
            //             \\pub const {s} = {s};
            //             \\
            //             \\
            //         , .{ alias, key });
            //     },
            //     .aliases => |aliases| {
            //         for (aliases) |alias| {
            //             try main_write.print(
            //                 \\pub const {s} = {s};
            //                 \\
            //                 \\
            //             , .{ alias, key });
            //         }
            //     },
            // }
            const str = (try string_map.get(key)).items;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/strs/blocks/", key), .{ .lock = .exclusive });
            defer str_file.close();
            var str_buf = std.io.bufferedWriter(str_file.writer());
            var str_write = str_buf.writer();
            try str_write.writeAll(header_txt);
            try str_write.print("pub const {s} = {};\n", .{ key, escString(str) });
            try str_buf.flush();
        }
    }

    // Create and write Runesets
    {
        var rune_map: RuneMap = .empty;
        for (sorted_keys) |key| {
            const this_str = (try string_map.get(key)).items;
            const this_runeset = try Runeset.createFromConstString(this_str, allocator);
            try rune_map.put(allocator, key, this_runeset);
        }
        const main_file = try std.fs.cwd()
            .createFile("src/sets/Blocks.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf = std.io.bufferedWriter(main_file.writer());
        var main_write = main_buf.writer();
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("blocks/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            // const other_names = gc_map.get(key).?;
            // switch (other_names) {
            //     .alias => |alias| {
            //         try main_write.print(
            //             \\pub const {s} = {s};
            //             \\
            //             \\
            //         , .{ alias, key });
            //     },
            //     .aliases => |aliases| {
            //         for (aliases) |alias| {
            //             try main_write.print(
            //                 \\pub const {s} = {s};
            //                 \\
            //                 \\
            //             , .{ alias, key });
            //         }
            //     },
            // }
            const rune = rune_map.get(key).?;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/sets/blocks/", key), .{ .lock = .exclusive });
            defer str_file.close();
            var str_buf = std.io.bufferedWriter(str_file.writer());
            var str_write = str_buf.writer();
            try str_write.writeAll(header_txt);
            try str_write.writeAll("const RuneSet = @import(\"runeset\").runeset;\n\n");
            try rune.serialize(str_write, .public, key);
            try str_buf.flush();
        }
        try main_buf.flush();
    }

    // Create and write Blocks enum
    {
        const main_file = try std.fs.cwd()
            .createFile("src/enums/Blocks.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf = std.io.bufferedWriter(main_file.writer());
        var main_write = main_buf.writer();
        try main_write.writeAll(header_txt);
        try main_write.writeAll("pub const BlocksKind = enum {\n");

        for (sorted_keys) |key| {
            try main_write.print("    {s},\n", .{key});
        }
        try main_write.writeAll("};\n");
        try main_buf.flush();
    }

    // This just gives visible output as a signal that the job was done.
    {
        const stdout = std.io.getStdOut();
        defer stdout.close();
        var writer = stdout.writer();
        for (sorted_keys) |key| {
            std.debug.print("{s} ", .{key});
        }
        try writer.print("\n", .{});
    }
    std.process.cleanExit();
}

const header_txt =
    \\//! Generated source!
    \\//! Do not modify!
    \\
    \\
;

fn normalize(buf: []u8, slice: []const u8) []const u8 {
    for (slice, 0..) |b, i| {
        switch (b) {
            ' ', '-' => buf[i] = '_',
            else => buf[i] = b,
        }
    }
    return buf[0..slice.len];
}

fn srcPath(tl: *TextList, prefix: []const u8, key: []const u8) ![]const u8 {
    try tl.appendSlice(prefix);
    try tl.appendSlice(key);
    try tl.appendSlice(".zig");
    return tl.toOwnedSlice();
}

const TextList = std.ArrayList(u8);
