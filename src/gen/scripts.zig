//! Scripts Generator
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
    const property_map = try tools.propertyMap(io, allocator);
    _ = property_map;
    var string_map: StringMap = .{ .allocator = allocator };
    var codepoint_map: CodepointMap = .{ .allocator = allocator };

    {
        var in_file = try std.Io.Dir.cwd().openFile(io, "UCD/Scripts.txt", .{});
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
    }

    const sorted_keys = try string_map.sortedKeys();
    var path_list: TextList = TextList.init(allocator);
    // Write strings files
    {
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/strs/Scripts.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const str = (try string_map.get(key)).items;
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/strs/scripts/", key), .{ .lock = .exclusive });
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
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/sets/Scripts.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const rune = rune_map.get(key).?;
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/sets/scripts/", key), .{ .lock = .exclusive });
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
    // Write codepoint files
    {
        try std.Io.Dir.cwd().createDirPath(io, "src/codepoints/scripts");
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/codepoints/Scripts.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const codepoints = (try codepoint_map.get(key)).items;
            var cp_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/codepoints/scripts/", key), .{ .lock = .exclusive });
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

    // Now for the interesting part: Script Extensions.
    //
    // First, we need to be able to map from the short forms to the long forms, that's in PropertyValueAliases:

    var short_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    {
        var in_file = try std.Io.Dir.cwd().openFile(io, "UCD/PropertyValueAliases.txt", .{});
        defer in_file.close(io);
        var in_buf: [4096]u8 = undefined;
        const in_reader = in_file.reader(io, &in_buf);
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        scan: while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const alias_cat = tok_iter.next().?;
            switch (alias_cat) {
                .label => |l| {
                    if (!std.mem.eql(u8, l.value(), "sc")) continue :scan;
                    const short_str = try allocator.dupe(u8, tok_iter.next().?.label.value());
                    const long_str = try allocator.dupe(u8, tok_iter.next().?.label.value());
                    try short_map.put(allocator, short_str, long_str);
                },
                .label_set => |ls| {
                    std.debug.print("I'm a label set? {s}\n", .{ls.slice});
                },
                else => {
                    continue :scan;
                },
            }
        }
    }

    // Now we just do some appending

    {
        var in_file = try std.Io.Dir.cwd().openFile(io, "UCD/ScriptExtensions.txt", .{});
        defer in_file.close(io);
        var in_buf: [4096]u8 = undefined;
        const in_reader = in_file.reader(io, &in_buf);
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const first = tok_iter.next().?;
            const cats = tok_iter.next().?;
            std.debug.assert(tok_iter.next() == null);
            switch (cats) {
                .label => |l| {
                    const label = l.value();
                    const maybe_long_label = short_map.get(label);
                    if (maybe_long_label) |long_label| {
                        const list = try string_map.get(long_label);
                        const codepoints = try codepoint_map.get(long_label);
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
                    } else {
                        std.debug.print("long not found for short: {s}\n", .{label});
                    }
                },
                .label_set => |ls_const| {
                    var ls = ls_const;
                    var label_iter = ls.iterator();
                    tokens: while (label_iter.next()) |label| {
                        if (label.len == 0) continue :tokens;
                        const maybe_long_label = short_map.get(label);
                        if (maybe_long_label) |long_label| {
                            const list = try string_map.get(long_label);
                            const codepoints = try codepoint_map.get(long_label);
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
                        } else {
                            std.debug.print("long in set not found for short: '{s}'\n", .{label});
                        }
                    }
                },
                else => unreachable,
            }
        }
    }

    // Now we do the whole thing over again with the slight variation introduced
    // This routine is in need of factoring, task for tomorrow I reckon
    //
    // Write strings files
    {
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/strs/ScriptsExtended.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts_ext/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const str = (try string_map.get(key)).items;
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/strs/scripts_ext/", key), .{ .lock = .exclusive });
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
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/sets/ScriptsExtended.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts_ext/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const rune = rune_map.get(key).?;
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/sets/scripts_ext/", key), .{ .lock = .exclusive });
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
    // Write codepoint files
    {
        try std.Io.Dir.cwd().createDirPath(io, "src/codepoints/scripts_ext");
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/codepoints/ScriptsExtended.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts_ext/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const codepoints = (try codepoint_map.get(key)).items;
            var cp_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/codepoints/scripts_ext/", key), .{ .lock = .exclusive });
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

    // Create and write Scripts enum
    {
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/enums/Scripts.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        try main_write.writeAll("pub const ScriptsKind = enum {\n");

        for (sorted_keys) |key| {
            try main_write.print("    {s},\n", .{key});
        }
        try main_write.writeAll("};\n\n");
        // const sorted_short_keys = try short_map.

        var short_sort = try allocator.alloc([]const u8, short_map.count());
        {
            var key_iter = short_map.keyIterator();
            var idx: usize = 0;
            while (key_iter.next()) |key| : (idx += 1) {
                short_sort[idx] = key.*;
            }
            std.mem.sort([]const u8, short_sort, {}, tools.ltString);
        }

        try main_write.writeAll("pub const ShortScriptsKind = enum {\n");
        for (short_sort) |key| {
            try main_write.print("    {s},\n", .{key});
        }
        try main_write.writeAll("};\n");
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
