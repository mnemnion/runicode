//! General Category Strings Generator
//!
//!

const std = @import("std");

const tools = @import("ucd-tools");
const escString = tools.ezcaper.escStringExactQuoted;

const CodepointMap = tools.CodepointMap;
const Runeset = tools.runeset.RuneSet;
const RuneMap = tools.RuneMap;

const LineIterator = tools.LineIterator;
const TokenIterator = tools.TokenIterator;
const StringMap = tools.StringMap;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var string_map: StringMap = .{ .allocator = allocator };
    var codepoint_map: CodepointMap = .{ .allocator = allocator };

    // TODO: Synonyms from PropertyValueAliases

    var in_file = try std.Io.Dir.cwd().openFile(io, "UCD/extracted/DerivedGeneralCategory.txt", .{});
    defer in_file.close(io);
    var in_buf: [4096]u8 = undefined;
    const in_reader = in_file.reader(io, &in_buf);
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
    const props_map = try tools.propertyMap(io, allocator);
    const gc_map = props_map.get("gc").?;
    // Write strings files
    {
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/strs/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
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
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/strs/gencat/", key), .{ .lock = .exclusive });
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
    // Create and write Runesets
    {
        var rune_map: RuneMap = .empty;
        for (sorted_keys) |key| {
            const this_str = (try string_map.get(key)).items;
            const this_runeset = try Runeset.createFromConstString(this_str, allocator);
            try rune_map.put(allocator, key, this_runeset);
        }

        {
            var supremum_str = TextList.init(allocator);
            var supremum_codepoints = std.array_list.Managed(u21).init(allocator);
            for (sorted_keys) |key| {
                if (!isSupremumGeneralCategory(key)) continue;
                try supremum_str.appendSlice((try string_map.get(key)).items);
                try supremum_codepoints.appendSlice((try codepoint_map.get(key)).items);
            }
            std.mem.sort(u21, supremum_codepoints.items, {}, ltCodepoint);
            const supremum_runeset = try Runeset.createFromConstString(supremum_str.items, allocator);

            const strs_supremum_file = try std.Io.Dir.cwd()
                .createFile(io, "src/strs/supremum.zig", .{ .lock = .exclusive });
            defer strs_supremum_file.close(io);
            var strs_supremum_buf: [4096]u8 = undefined;
            var strs_supremum_writer = strs_supremum_file.writer(io, &strs_supremum_buf);
            const strs_supremum_write = &strs_supremum_writer.interface;
            try strs_supremum_write.writeAll(header_txt);
            try strs_supremum_write.print("pub const assigned_public = {f};\n", .{escString(supremum_str.items)});
            try strs_supremum_write.flush();

            const sets_supremum_file = try std.Io.Dir.cwd()
                .createFile(io, "src/sets/supremum.zig", .{ .lock = .exclusive });
            defer sets_supremum_file.close(io);
            var sets_supremum_buf: [4096]u8 = undefined;
            var sets_supremum_writer = sets_supremum_file.writer(io, &sets_supremum_buf);
            const sets_supremum_write = &sets_supremum_writer.interface;
            try sets_supremum_write.writeAll(header_txt);
            try sets_supremum_write.writeAll("const RuneSet = @import(\"runeset\").RuneSet;\n\n");
            try sets_supremum_write.print("// Length: {d}.\n", .{supremum_runeset.body.len});
            try supremum_runeset.serialize(sets_supremum_write, .public, "assigned_public");
            try sets_supremum_write.flush();

            const codepoints_supremum_file = try std.Io.Dir.cwd()
                .createFile(io, "src/codepoints/supremum.zig", .{ .lock = .exclusive });
            defer codepoints_supremum_file.close(io);
            var codepoints_supremum_buf: [4096]u8 = undefined;
            var codepoints_supremum_writer = codepoints_supremum_file.writer(io, &codepoints_supremum_buf);
            const codepoints_supremum_write = &codepoints_supremum_writer.interface;
            try codepoints_supremum_write.writeAll(header_txt);
            try tools.writeCodepointArray(codepoints_supremum_write, "assigned_public", supremum_codepoints.items);
            try codepoints_supremum_write.flush();
        }

        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/sets/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
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
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/sets/gencat/", key), .{ .lock = .exclusive });
            defer str_file.close(io);
            var str_buf: [4096]u8 = undefined;
            var str_writer = str_file.writer(io, &str_buf);
            const str_write = &str_writer.interface;
            try str_write.writeAll(header_txt);
            try str_write.writeAll("const RuneSet = @import(\"runeset\").RuneSet;\n\n");
            try str_write.print("// Length: {d}.\n", .{rune.body.len});
            try rune.serialize(str_write, .public, key);
            try str_write.flush();
        }
        try main_write.flush();
    }
    // Create and write General Category enum
    {
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/enums/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
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
        try std.Io.Dir.cwd().createDirPath(io, "src/codepoints/gencat");
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/codepoints/GeneralCategory.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
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
            var cp_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/codepoints/gencat/", key), .{ .lock = .exclusive });
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

    // This just gives visible output as a signal that the job was done.
    {
        var stdout_buf: [64]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
        const writer = &stdout_writer.interface;
        for (sorted_keys) |key| {
            try writer.print("{s} ", .{key});
        }
        try writer.writeByte('\n');
        try writer.flush();
    }
    std.process.cleanExit(io);
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
