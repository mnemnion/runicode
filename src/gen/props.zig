//! Derived Core Properties
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

    // Properties

    {
        var in_file = try std.fs.cwd().openFile("UCD/PropList.txt", .{});
        defer in_file.close();
        var in_buf = std.io.bufferedReader(in_file.reader());
        const in_reader = in_buf.reader();
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const first = tok_iter.next().?;
            const cat_token = tok_iter.next().?.label;
            if (tok_iter.next()) |tok| {
                std.debug.print("Unexpected token: {}\n", .{tok});
            }
            const cat = cat_token.value();
            const list = try string_map.get(cat);
            switch (first) {
                .label, .hyphenated, .number, .none, .sequence, .label_set => unreachable,
                .point => |pt| {
                    try pt.append(allocator, list);
                },
                .range => |r| {
                    try r.append(allocator, list);
                },
            }
        }
    }

    // Derived Core Properties

    // TODO: Synonyms from PropertyValueAliases

    {
        var in_file = try std.fs.cwd().openFile("UCD/DerivedCoreProperties.txt", .{});
        defer in_file.close();
        var in_buf = std.io.bufferedReader(in_file.reader());
        const in_reader = in_buf.reader();
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const first = tok_iter.next().?;
            const cat_token = tok_iter.next().?.label;
            if (tok_iter.next()) |tok| {
                // TODO: These are all Indian Conjunct Break InCB, the important classifier is
                // this third category.  Let's do something about it...
                _ = tok;
            }
            const cat = cat_token.value();
            const list = try string_map.get(cat);
            switch (first) {
                .label, .hyphenated, .number, .none, .sequence, .label_set => unreachable,
                .point => |pt| {
                    try pt.append(allocator, list);
                },
                .range => |r| {
                    try r.append(allocator, list);
                },
            }
        }
    }

    {
        var in_file = try std.fs.cwd().openFile("UCD/emoji/emoji-data.txt", .{});
        defer in_file.close();
        var in_buf = std.io.bufferedReader(in_file.reader());
        const in_reader = in_buf.reader();
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const first = tok_iter.next().?;
            const cat_token = tok_iter.next().?.label;
            if (tok_iter.next()) |tok| {
                // TODO: These are all Indian Conjunt Break InCB, the important classifier is
                // this third category.  Let's do something about it...
                _ = tok;
            }
            const cat = cat_token.value();
            const list = try string_map.get(cat);
            switch (first) {
                .label, .hyphenated, .number, .none, .sequence, .label_set => unreachable,
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
            .createFile("src/strs/CoreProperties.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_write = main_file.writer();
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            if (std.mem.eql(u8, "Hyphen", key)) {
                try main_write.writeAll("// Deprecated property as of Unicode 6.0.  Use is discouraged.\n");
            }
            try main_write.print(
                \\pub const {s} = @import("props/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const str = (try string_map.get(key)).items;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/strs/props/", key), .{ .lock = .exclusive });
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
            .createFile("src/sets/CoreProperties.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf = std.io.bufferedWriter(main_file.writer());
        var main_write = main_buf.writer();
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("props/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const rune = rune_map.get(key).?;
            var str_file = try std.fs.cwd()
                .createFile(try srcPath(&path_list, "src/sets/props/", key), .{ .lock = .exclusive });
            defer str_file.close();
            var str_buf = std.io.bufferedWriter(str_file.writer());
            var str_write = str_buf.writer();
            try str_write.writeAll(header_txt);
            try str_write.writeAll("const RuneSet = @import(\"runeset\").runeset;\n\n");
            try str_write.print("// Length: {d}.\n", .{rune.body.len});
            try rune.serialize(str_write, .public, key);
            try str_buf.flush();
        }
        try main_buf.flush();
    }

    // Create and write CoreProperties enum
    {
        const main_file = try std.fs.cwd()
            .createFile("src/enums/CoreProperties.zig", .{ .lock = .exclusive });
        defer main_file.close();
        var main_buf = std.io.bufferedWriter(main_file.writer());
        var main_write = main_buf.writer();
        try main_write.writeAll(header_txt);
        try main_write.writeAll("pub const CorePropertyKind = enum {\n");

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

fn srcPath(tl: *TextList, prefix: []const u8, key: []const u8) ![]const u8 {
    try tl.appendSlice(prefix);
    try tl.appendSlice(key);
    try tl.appendSlice(".zig");
    return tl.toOwnedSlice();
}

const TextList = std.ArrayList(u8);
