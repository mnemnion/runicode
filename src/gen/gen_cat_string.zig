//! General Category Strings Generator
//!
//!

const std = @import("std");

const tools = @import("ucd-tools");
const escString = tools.ezcaper.escStringExact;

const LineIterator = tools.LineIterator;
const TokenIterator = tools.TokenIterator;
const StringMap = tools.StringMap;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var string_map: StringMap = .{ .allocator = allocator };

    var in_file = try std.fs.cwd().openFile("UCD/extracted/DerivedGeneralCategory.txt", .{});
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
    const sorted_keys = try string_map.sortedKeys();

    const main_file = try std.fs.cwd()
        .createFile("src/strs/gencat.zig", .{ .lock = .exclusive });
    defer main_file.close();
    var main_write = main_file.writer();
    try main_write.writeAll(header_txt);
    var path_list: TextList = TextList.init(allocator);
    for (sorted_keys) |key| {
        try main_write.print(
            \\pub const {s} = @import("./gencat/{s}.zig").{s};
            \\
            \\
        , .{ key, key, key });
        const str = string_map.map.get(key).?.items;
        var str_file = try std.fs.cwd()
            .createFile(try srcPath(&path_list, key), .{ .lock = .exclusive });
        defer str_file.close();
        var str_write = str_file.writer();
        try str_write.writeAll(header_txt);
        try str_write.print("pub const {s} = {};\n", .{ key, escString(str) });
    }

    const stdout = std.io.getStdOut();
    defer stdout.close();
    var writer = stdout.writer();
    for (sorted_keys) |key| {
        std.debug.print("{s} ", .{key});
    }
    try writer.print("\n", .{});
    std.process.cleanExit();
}

const header_txt =
    \\//! Generated source!
    \\//! Do not modify!
    \\
    \\
;

fn srcPath(tl: *TextList, key: []const u8) ![]const u8 {
    try tl.appendSlice("src/strs/gencat/");
    try tl.appendSlice(key);
    try tl.appendSlice(".zig");
    return tl.toOwnedSlice();
}

const TextList = std.ArrayList(u8);
