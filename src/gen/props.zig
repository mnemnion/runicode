//! Derived Core Properties
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var string_map: StringMap = .{ .allocator = allocator };
    var codepoint_map: CodepointMap = .{ .allocator = allocator };

    // Properties

    {
        var in_file = try std.Io.Dir.cwd().openFile(io, "UCD/PropList.txt", .{});
        defer in_file.close(io);
        var in_buf: [4096]u8 = undefined;
        const in_reader = in_file.reader(io, &in_buf);
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const first = tok_iter.next().?;
            const cat_token = tok_iter.next().?.label;
            if (tok_iter.next()) |tok| {
                std.debug.print("Unexpected token: {any}\n", .{tok});
            }
            const cat = cat_token.value();
            const list = try string_map.get(cat);
            const codepoints = try codepoint_map.get(cat);
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

    // Derived Core Properties

    // TODO: Synonyms from PropertyValueAliases

    {
        var in_file = try std.Io.Dir.cwd().openFile(io, "UCD/DerivedCoreProperties.txt", .{});
        defer in_file.close(io);
        var in_buf: [4096]u8 = undefined;
        const in_reader = in_file.reader(io, &in_buf);
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
            const codepoints = try codepoint_map.get(cat);
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

    {
        var in_file = try std.Io.Dir.cwd().openFile(io, "UCD/emoji/emoji-data.txt", .{});
        defer in_file.close(io);
        var in_buf: [4096]u8 = undefined;
        const in_reader = in_file.reader(io, &in_buf);
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
            const codepoints = try codepoint_map.get(cat);
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

    const sorted_keys = try string_map.sortedKeys();
    var path_list: TextList = TextList.init(allocator);
    // Write strings files
    {
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/strs/CoreProperties.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
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
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/strs/props/", key), .{ .lock = .exclusive });
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
            .createFile(io, "src/sets/CoreProperties.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);

        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("props/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const rune = rune_map.get(key).?;
            var str_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/sets/props/", key), .{ .lock = .exclusive });
            defer str_file.close(io);
            var str_buf: [4096]u8 = undefined;
            var str_writer = str_file.writer(io, &str_buf);
            const str_write = &str_writer.interface;
            try str_write.writeAll(header_txt);
            try str_write.writeAll("const RuneSet = @import(\"runeset\").runeset;\n\n");
            try str_write.print("// Length: {d}.\n", .{rune.body.len});
            try rune.serialize(str_write, .public, key);
            try str_write.flush();
        }
        try main_write.flush();
    }

    // Create and write CoreProperties enum
    {
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/enums/CoreProperties.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        try main_write.writeAll("pub const CorePropertyKind = enum {\n");

        for (sorted_keys) |key| {
            try main_write.print("    {s},\n", .{key});
        }
        try main_write.writeAll("};\n");
        try main_write.flush();
    }
    // Write codepoint files
    {
        try std.Io.Dir.cwd().createDirPath(io, "src/codepoints/props");
        const main_file = try std.Io.Dir.cwd()
            .createFile(io, "src/codepoints/CoreProperties.zig", .{ .lock = .exclusive });
        defer main_file.close(io);
        var main_buf: [4096]u8 = undefined;
        var main_writer = main_file.writer(io, &main_buf);
        const main_write = &main_writer.interface;
        try main_write.writeAll(header_txt);
        for (sorted_keys) |key| {
            try main_write.print(
                \\pub const {s} = @import("props/{s}.zig").{s};
                \\
                \\
            , .{ key, key, key });
            const codepoints = (try codepoint_map.get(key)).items;
            var cp_file = try std.Io.Dir.cwd()
                .createFile(io, try srcPath(&path_list, "src/codepoints/props/", key), .{ .lock = .exclusive });
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
