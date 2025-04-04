//! General Category Strings Generator
//!
//!

const std = @import("std");

const tools = @import("ucd-tools.zig");
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
    errdefer {
        // Report line_iter problems
    }
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
    var map_iter = string_map.iterator();
    while (map_iter.next()) |entry| {
        std.debug.print("{s}: {s}\n\n", .{ entry.key_ptr.*, entry.value_ptr.*.items });
    }
}
