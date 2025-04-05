//! Scripts Generator
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

    {
        var in_file = try std.fs.cwd().openFile("UCD/Scripts.txt", .{});
        defer in_file.close();
        var in_buf = std.io.bufferedReader(in_file.reader());
        const in_reader = in_buf.reader();
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const first = tok_iter.next().?;
            const cat_token = tok_iter.next().?.label;
            std.debug.assert(tok_iter.next() == null);
            const cat = cat_token.value();
            const list = try string_map.get(cat);
            switch (first) {
                .label, .none, .sequence, .label_set => unreachable,
                .point => |pt| {
                    try pt.append(allocator, list);
                },
                .range => |r| {
                    try r.append(allocator, list);
                },
            }
        }
    }

    const sorted_keys = try string_map.sortedKeys();
    var path_list: TextList = TextList.init(allocator);
    // Write strings files
    {
        const main_file = try std.fs.cwd()
            .createFile("src/strs/Scripts.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_write = main_file.writer();
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const str = (try string_map.get(key)).items;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/strs/scripts/", key), .{ .lock = .exclusive });
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
            .createFile("src/sets/Scripts.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf = std.io.bufferedWriter(main_file.writer());
        var main_write = main_buf.writer();
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const rune = rune_map.get(key).?;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/sets/scripts/", key), .{ .lock = .exclusive });
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

    // Now for the interesting part: Script Extensions.
    //
    // First, we need to be able to map from the short forms to the long forms, that's in PropertyValueAliases:

    var short_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    {
        var in_file = try std.fs.cwd().openFile("UCD/PropertyValueAliases.txt", .{});
        defer in_file.close();
        var in_buf = std.io.bufferedReader(in_file.reader());
        const in_reader = in_buf.reader();
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
        var in_file = try std.fs.cwd().openFile("UCD/ScriptExtensions.txt", .{});
        defer in_file.close();
        var in_buf = std.io.bufferedReader(in_file.reader());
        const in_reader = in_buf.reader();
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
                        switch (first) {
                            .label, .none, .sequence, .label_set => unreachable,
                            .point => |pt| {
                                try pt.append(allocator, list);
                            },
                            .range => |r| {
                                try r.append(allocator, list);
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
                            switch (first) {
                                .label, .none, .sequence, .label_set => unreachable,
                                .point => |pt| {
                                    try pt.append(allocator, list);
                                },
                                .range => |r| {
                                    try r.append(allocator, list);
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
        const main_file = try std.fs.cwd()
            .createFile("src/strs/ScriptsExtended.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_write = main_file.writer();
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts_ext/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const str = (try string_map.get(key)).items;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/strs/scripts_ext/", key), .{ .lock = .exclusive });
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
            .createFile("src/sets/ScriptsExtended.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf = std.io.bufferedWriter(main_file.writer());
        var main_write = main_buf.writer();
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("scripts_ext/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const rune = rune_map.get(key).?;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/sets/scripts_ext/", key), .{ .lock = .exclusive });
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

fn srcPath(tl: *TextList, prefix: []const u8, key: []const u8) ![]const u8 {
    try tl.appendSlice(prefix);
    try tl.appendSlice(key);
    try tl.appendSlice(".zig");
    return tl.toOwnedSlice();
}

const TextList = std.ArrayList(u8);
