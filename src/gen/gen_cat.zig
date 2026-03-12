//! General Category Strings Generator
//!
//!

const std = @import("std");

const tools = @import("ucd-tools");
const escString = tools.ezcaper.escStringExactQuoted;

const CodepointMap = tools.CodepointMap;
const Runeset = tools.runeset.runeset.RuneSet;
const RuneMap = tools.RuneMap;

const LineIterator = tools.LineIterator;
const TokenIterator = tools.TokenIterator;
const StringMap = tools.StringMap;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var string_map: StringMap = .{ .allocator = allocator };
    var codepoint_map: CodepointMap = .{ .allocator = allocator };

    // TODO: Synonyms from PropertyValueAliases

    var in_file = try std.fs.cwd().openFile("UCD/extracted/DerivedGeneralCategory.txt", .{});
    defer in_file.close();
    var in_buf: [4096]u8 = undefined;
    const in_reader = in_file.reader(&in_buf);
    var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
    while (try line_iter.next()) |tok_iter_const| {
        var tok_iter = tok_iter_const;
        const first = tok_iter.next().?;
        const cat_token = tok_iter.next().?.label;
        std.debug.assert(tok_iter.next() == null);
        const cat = cat_token.value();
        const list = try string_map.get(cat);
        const codepoints = try codepoint_map.get(cat);
        switch (first) {
            .label, .hyphenated, .none, .number, .sequence, .label_set => unreachable,
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
    const sorted_keys = try string_map.sortedKeys();
    var path_list: TextList = TextList.init(allocator);
    const props_map = try tools.propertyMap(allocator);
    const gc_map = props_map.get("gc").?;
    // Write strings files
    {
        const main_file = try std.fs.cwd()
            .createFile("src/strs/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(&main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("gencat/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const other_names = gc_map.get(key).?;
            switch (other_names) {
                .alias => |alias| {
                    try main_write.print(
                        \\pub const {s} = {s};
                        \\
                        \\
                    , .{ alias, key });
                },
                .aliases => |aliases| {
                    for (aliases) |alias| {
                        try main_write.print(
                            \\pub const {s} = {s};
                            \\
                            \\
                        , .{ alias, key });
                    }
                },
            }
            const str = (try string_map.get(key)).items;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/strs/gencat/", key), .{ .lock = .exclusive });
            defer str_file.close();
            var str_buf: [4096]u8 = undefined;
            var str_writer = str_file.writer(&str_buf);
            const str_write = &str_writer.interface;
            try str_write.writeAll(header_txt);
            try str_write.print("pub const {s} = {f};\n", .{ key, escString(str) });
            try str_write.flush();
        }
        try main_write.flush();
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
            .createFile("src/sets/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(&main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("gencat/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const other_names = gc_map.get(key).?;
            switch (other_names) {
                .alias => |alias| {
                    try main_write.print(
                        \\pub const {s} = {s};
                        \\
                        \\
                    , .{ alias, key });
                },
                .aliases => |aliases| {
                    for (aliases) |alias| {
                        try main_write.print(
                            \\pub const {s} = {s};
                            \\
                            \\
                        , .{ alias, key });
                    }
                },
            }
            const rune = rune_map.get(key).?;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/sets/gencat/", key), .{ .lock = .exclusive });
            defer str_file.close();
            var str_buf: [4096]u8 = undefined;
            var str_writer = str_file.writer(&str_buf);
            const str_write = &str_writer.interface;
            try str_write.writeAll(header_txt);
            try str_write.writeAll("const RuneSet = @import(\"runeset\").runeset;\n\n");
            try str_write.print("// Length: {d}.\n", .{rune.body.len});
            try rune.serialize(str_write, .public, key);
            try str_write.flush();
        }
        try main_write.flush();
    }
    // Create and write General Category enum
    {
        const main_file = try std.fs.cwd()
            .createFile("src/enums/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(&main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        try main_write.writeAll("pub const GeneralCategoryKind = enum {\n");

        for (sorted_keys) |key| {
            try main_write.print("    {s},\n", .{key});
        }
        try main_write.writeAll("};\n");
        try main_write.flush();
    }
    // Write codepoint files
    {
        try std.fs.cwd().makePath("src/codepoints/gencat");
        const main_file = try std.fs.cwd()
            .createFile("src/codepoints/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(&main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("gencat/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const other_names = gc_map.get(key).?;
            switch (other_names) {
                .alias => |alias| {
                    try main_write.print(
                        \\pub const {s} = {s};
                        \\
                        \\
                    , .{ alias, key });
                },
                .aliases => |aliases| {
                    for (aliases) |alias| {
                        try main_write.print(
                            \\pub const {s} = {s};
                            \\
                            \\
                        , .{ alias, key });
                    }
                },
            }
            const codepoints = (try codepoint_map.get(key)).items;
            var cp_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/codepoints/gencat/", key), .{ .lock = .exclusive });
            defer cp_file.close();
            var cp_buf: [4096]u8 = undefined;
            var cp_writer = cp_file.writer(&cp_buf);
            const cp_write = &cp_writer.interface;
            try cp_write.writeAll(header_txt);
            try tools.writeCodepointArray(cp_write, key, codepoints);
            try cp_write.flush();
        }
        try main_write.flush();
    }

    // This just gives visible output as a signal that the job was done.
    {
        const writer = std.fs.File.stdout().deprecatedWriter();
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

fn srcPath(tl: *TextList, prefix: []const u8, key: []const u8) ![]const u8 {
    try tl.appendSlice(prefix);
    try tl.appendSlice(key);
    try tl.appendSlice(".zig");
    return tl.toOwnedSlice();
}

const TextList = std.array_list.Managed(u8);
