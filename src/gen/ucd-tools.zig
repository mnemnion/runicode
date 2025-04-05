//! UCD Tools
//!
//! A library for convenient Zig parsing of Unicode data files.
//!
//! With various inspirations and borrowings from zg.
//!

// Forward-import ezcaper module

pub const ezcaper = @import("ezcaper");

const esc_string = ezcaper.escStringExact;

pub fn ltString(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.order(u8, l, r) == .lt;
}

// TODO: At least the GraphemeTest.txt file has lines which I suspect are
// longer than 4k.  Let's keep that in mind.

pub const DecodeError = error{
    OutOfMemory,
    TokenProblem,
};

/// Iterator over lines.  Each call to `next` invalidates both the
/// contents of the TokenIterator, and each Token returned by it.
pub fn LineIterator(Reader: type) type {
    return struct {
        read: Reader,
        buf: [4096]u8 = undefined,

        pub const LineIter = @This();

        pub fn next(iter: *LineIter) !?TokenIterator {
            while (try iter.read.readUntilDelimiterOrEof(&iter.buf, '\n')) |line| {
                if (line.len == 0 or line[0] == '#') continue;
                return if (std.mem.indexOfScalar(u8, line, '#')) |hash|
                    .{ .line = line[0..hash] }
                else
                    .{ .line = line };
            }
            return null;
        }
    };
}

pub const TokenIterator = struct {
    line: []const u8,
    idx: usize = 0,
    col: usize = 0, // one-based

    // NOTE: The below relies on certain regularities within the data, to whit:
    // - There are expected to be no range + point sets
    // - No label + point sets
    // - No 'weird' symbols.  This is _not_ always true, unclear if they are only in tests
    // --
    // Believed to be regular but not assumed:
    // - No space at first column
    // - Only one space after separators
    //

    pub fn next(iter: *TokenIterator) ?Token {
        if (iter.idx == iter.line.len) return null;
        const start = iter.idx;

        var contents: bool = false; // Whitespace guard, _probably_ not needed
        var more_contents: bool = false;
        var alpha: bool = false;
        var separator: bool = false;
        var range: bool = false;
        scan: while (iter.idx < iter.line.len) : (iter.idx += 1) {
            const b = iter.line[iter.idx];
            switch (b) {
                ' ' => {
                    if (contents) {
                        separator = true;
                    }
                },
                '0'...'9', 'A'...'F' => {
                    // Assumption: there will be no all-numeric-hex fields which are not numbers,
                    // but are instead labels.  Probably true: SHOUTING CASE is used for codepoint
                    // names, and it would be an astonishing mistake if any of those happened to be
                    // accidentally-hexadecimal.  Then again, I've been astonished before.
                    if (separator) {
                        more_contents = true;
                    }
                    contents = true;
                },
                '.' => {
                    assert(iter.idx + 1 < iter.line.len and iter.line[iter.idx + 1] == '.');
                    range = true;
                    iter.idx += 1;
                },
                ';' => {
                    iter.idx += 1;
                    break :scan;
                },
                else => {
                    assert(std.ascii.isAlphabetic(b));
                    if (separator) {
                        more_contents = true;
                    }
                    contents = true;
                    alpha = true;
                },
            }
        }
        const stop: usize = if (iter.idx == 0) 0 else iter.idx - 1;
        iter.col += 1;
        // Handle trailing space in next field optimistically
        // (if I'm right, this obviates 'contents').
        if (iter.idx < iter.line.len and iter.line[iter.idx] == ' ') iter.idx += 1;
        // empty?
        if (!contents) return .none;
        const slice = iter.line[start..stop];
        if (alpha) {
            if (more_contents) {
                return .{ .label_set = .{ .slice = slice } };
            } else {
                return .{ .label = .{ .slice = slice } };
            }
        } else if (range) {
            return .{ .range = .{ .slice = slice } };
        } else {
            if (more_contents) {
                return .{ .sequence = .{ .slice = slice } };
            } else {
                return .{ .point = .{ .slice = slice } };
            }
        }
        unreachable;
    }
};

pub const Token = union(TokenKind) {
    none: void,
    point: Point,
    range: Range,
    label: Label,
    sequence: Sequence,
    label_set: LabelSet,
};

pub const TokenKind = enum(u3) {
    none,
    point,
    range,
    label,
    sequence,
    label_set,
};

pub const Point = struct {
    slice: []const u8,

    pub fn append(point: Point, allocator: Allocator, list: *TextList) DecodeError!void {
        var buf: [4]u8 = undefined;
        // If this fails we can act accordingly:
        assert(point.slice[0] != ' ');
        const utf8 = try encodeOne(buf[0..4], point.slice);
        try list.appendSlice(allocator, utf8);
    }
};

fn encodeOne(buf: []u8, slice: []const u8) error{TokenProblem}![]const u8 {
    var idx: usize = 0;
    while (std.ascii.isHex(slice[idx])) : (idx += 1) {}
    const codepoint = std.fmt.parseInt(u21, slice[0..idx], 16) catch {
        return error.TokenProblem;
    };
    const len = std.unicode.wtf8Encode(codepoint, buf) catch {
        return error.TokenProblem;
    };
    return buf[0..len];
}

pub const Range = struct {
    slice: []const u8,

    pub fn append(range: Range, allocator: Allocator, list: *TextList) DecodeError!void {
        var buf: [4]u8 = undefined;
        var idx: usize = 0;
        while (std.ascii.isHex(range.slice[idx])) : (idx += 1) {}
        const start = std.fmt.parseInt(u21, range.slice[0..idx], 16) catch {
            return error.TokenProblem;
        };
        assert(range.slice[idx] == '.');
        idx += 1;
        assert(range.slice[idx] == '.');
        idx += 1;
        const two = idx;
        while (idx < range.slice.len and std.ascii.isHex(range.slice[idx])) : (idx += 1) {}
        const end = std.fmt.parseInt(u21, range.slice[two..idx], 16) catch {
            return error.TokenProblem;
        };
        for (start..end) |cp_usize| {
            const codepoint: u21 = @intCast(cp_usize);
            const len = std.unicode.wtf8Encode(codepoint, &buf) catch {
                return error.TokenProblem;
            };
            try list.appendSlice(allocator, buf[0..len]);
        }
    }
};

pub const Label = struct {
    slice: []const u8,

    pub fn value(label: Label) []const u8 {
        var start: usize = 0;
        while (label.slice[start] == ' ') : (start += 1) {}
        var end = start;
        while (end < label.slice.len and std.ascii.isAlphabetic(label.slice[end])) : (end += 1) {}
        return label.slice[start..end];
    }
};

pub const Sequence = struct {
    slice: []const u8,

    pub fn append(seq: Sequence, allocator: Allocator, list: *TextList) !void {
        var iter = std.mem.splitScalar(u8, seq.slice, ' ');
        var buf: [4]u8 = undefined;
        while (iter.next()) |tok| {
            if (tok.len == 0) continue;
            const utf8 = encodeOne(&buf, tok);
            try list.appendSlice(allocator, utf8);
        }
    }
};

pub const LabelSet = struct {
    slice: []const u8,
};

pub const StringMap = struct {
    allocator: Allocator,
    map: StringHash = .empty,

    pub fn get(str_map: *StringMap, key: []const u8) !*TextList {
        if (str_map.map.getPtr(key)) |ptr| {
            return ptr;
        }
        const key_clone = try str_map.allocator.dupe(u8, key);
        const new_map: TextList = .empty;
        try str_map.map.put(str_map.allocator, key_clone, new_map);
        return str_map.map.getPtr(key).?;
    }

    pub fn iterator(str_map: *StringMap) StringHash.Iterator {
        return str_map.map.iterator();
    }

    /// Allocates and returns a slice with the map's keys sorted in
    /// lexicographical order. In intended use the arena frees this
    /// allocation.
    pub fn sortedKeys(str_map: *StringMap) ![][]const u8 {
        var sorted_keys = try str_map.allocator.alloc([]const u8, str_map.map.count());
        {
            var key_iter = str_map.map.keyIterator();
            var idx: usize = 0;
            while (key_iter.next()) |key| : (idx += 1) {
                sorted_keys[idx] = key.*;
            }
            std.mem.sort([]const u8, sorted_keys, {}, ltString);
        }
        return sorted_keys;
    }

    const FmtOps = std.fmt.FormatOptions;

    pub fn format(str_map: *StringMap, _: []const u8, _: FmtOps, writer: anytype) !void {
        var iter = str_map.iterator();
        while (iter.next()) |entry| {
            try writer.print("pub const {s} = {};\n\n", .{ entry.key_ptr.*, esc_string(entry.value_ptr.items) });
        }
    }
};

// TODO: Write unicoder out of runeset and use that instead of std.unicode

const std = @import("std");
const assert = std.debug.assert;
const TextList = std.ArrayListUnmanaged(u8);
const Allocator = std.mem.Allocator;
const StringHash = std.StringHashMapUnmanaged(TextList);
