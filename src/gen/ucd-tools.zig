//! UCD Tools
//!
//! A library for convenient Zig parsing of Unicode data files.
//!
//! With various inspirations and borrowings from zg.
//!

// TODO: Write unicoder out of runeset and use that instead of std.unicode

// Forward-import ezcaper and runeset modules

pub const ezcaper = @import("ezcaper");

pub const runeset = @import("runeset");

pub fn ltString(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.order(u8, l, r) == .lt;
}

// TODO: A data structure for PropertyValueAliases, it's going to get used
// in a lot of places.

// NOTE: At least the GraphemeTest.txt file has lines which I suspect are
// longer than 4k.  Let's keep that in mind.

// TODO: This isn't used in a proper way. Probably we dispose
pub const DecodeError = error{
    OutOfMemory,
    TokenProblem,
};

/// Iterator over lines.  Each call to `next` invalidates both the
/// contents of the TokenIterator, and each Token returned by it.
pub fn LineIterator(Reader: type) type {
    return struct {
        read: Reader,
        // Longest line in the database as of 16.0: 25541. Page align to 4K:
        buf: [28_672]u8 = undefined,
        line: usize = 0,
        pub const LineIter = @This();

        pub fn next(iter: *LineIter) !?TokenIterator {
            while (try takeLine(&iter.read)) |line| {
                iter.line += 1;
                if (line.len == 0 or line[0] == '#') continue;
                return if (std.mem.indexOfScalar(u8, line, '#')) |hash|
                    .{ .line = line[0..hash] }
                else
                    .{ .line = line };
            }
            return null;
        }

        fn takeLine(read: *Reader) !?[]const u8 {
            if (@hasField(Reader, "interface")) {
                return try read.interface.takeDelimiter('\n');
            }
            return try read.takeDelimiter('\n');
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
        var hyphen: bool = false;
        var dot: bool = false;
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
                    if (iter.idx + 1 < iter.line.len and iter.line[iter.idx + 1] == '.') {
                        range = true;
                        iter.idx += 1;
                    } else {
                        dot = true;
                    }
                },
                ';' => {
                    break :scan;
                },
                '-' => {
                    hyphen = true;
                },
                else => {
                    if (!(std.ascii.isAlphabetic(b) or b == '_')) {
                        std.debug.panic("unexpected byte {u} {d}", .{ b, b });
                    }
                    if (separator) {
                        more_contents = true;
                    }
                    contents = true;
                    alpha = true;
                },
            }
        }
        const stop: usize = iter.idx;
        if (iter.idx < iter.line.len and iter.line[iter.idx] == ';') {
            iter.idx += 1;
        }
        iter.col += 1;
        // Handle trailing space in next field optimistically
        if (iter.idx < iter.line.len and iter.line[iter.idx] == ' ') iter.idx += 1;
        // empty?
        if (!contents) return .none;
        const slice = iter.line[start..stop];
        const tok = std.mem.trim(u8, slice, " ");

        if (dot and !alpha) {
            return .{ .number = .{ .slice = tok } };
        }
        if (hyphen) return .{ .hyphenated = .{ .slice = tok } };
        if (alpha) {
            if (more_contents) {
                return .{ .label_set = .{ .slice = tok } };
            } else {
                return .{ .label = .{ .slice = tok } };
            }
        } else if (range) {
            return .{ .range = .{ .slice = tok } };
        } else {
            if (more_contents) {
                return .{ .sequence = .{ .slice = tok } };
            } else {
                // Problem token: F
                if (tok.len >= 4)
                    return .{ .point = .{ .slice = tok } }
                else // TODO: Might be dotless numbers?
                    return .{ .label = .{ .slice = tok } };
            }
        }
        unreachable;
    }
};

pub const Token = union(TokenKind) {
    none: void,
    point: Point,
    number: Number,
    range: Range,
    label: Label,
    hyphenated: HyphenLabel,
    sequence: Sequence,
    label_set: LabelSet,

    pub fn format(token: Token, _: []const u8, _: FmtOps, writer: anytype) !void {
        switch (token) {
            .none => try writer.writeAll(".none"),
            .point => |p| try writer.print(".point = {s}", .{p.slice}),
            .number => |n| try writer.print(".point = {s}", .{n.slice}),
            .range => |r| try writer.print(".range = {s}", .{r.slice}),
            .sequence => |s| try writer.print(".sequence = {s}", .{s.slice}),
            .label => |l| try writer.print(".label = {s}", .{l.slice}),
            .hyphenated => |h| try writer.print(".hyphen = {s}", .{h.slice}),
            .label_set => |ls| try writer.print(".label_set = {s}", .{ls.slice}),
        }
    }
};

pub const TokenKind = enum(u3) {
    none,
    point,
    number,
    range,
    label,
    hyphenated,
    sequence,
    label_set,
};

pub const Number = struct {
    slice: []const u8,
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

    pub fn appendCodepoint(point: Point, allocator: Allocator, list: *CodepointList) DecodeError!void {
        const cp = try point.codepoint();
        try list.append(allocator, cp);
    }

    fn codepoint(point: Point) error{TokenProblem}!u21 {
        var idx: usize = 0;
        while (idx < point.slice.len and std.ascii.isHex(point.slice[idx])) : (idx += 1) {}
        return std.fmt.parseInt(u21, point.slice[0..idx], 16) catch {
            return error.TokenProblem;
        };
    }
};

fn encodeOne(buf: []u8, slice: []const u8) error{TokenProblem}![]const u8 {
    var idx: usize = 0;
    while (idx < slice.len and std.ascii.isHex(slice[idx])) : (idx += 1) {}
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
        for (start..end + 1) |cp_usize| {
            const codepoint: u21 = @intCast(cp_usize);
            const len = std.unicode.wtf8Encode(codepoint, &buf) catch {
                return error.TokenProblem;
            };
            try list.appendSlice(allocator, buf[0..len]);
        }
    }

    pub fn appendCodepoints(range: Range, allocator: Allocator, list: *CodepointList) DecodeError!void {
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
        for (start..end + 1) |cp_usize| {
            const codepoint: u21 = @intCast(cp_usize);
            try list.append(allocator, codepoint);
        }
    }
};

pub const Label = struct {
    slice: []const u8,

    pub fn value(label: Label) []const u8 {
        return label.slice;
    }
};

pub const HyphenLabel = struct {
    slice: []const u8,

    pub fn value(hyphen: HyphenLabel) []const u8 {
        return hyphen.slice;
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

    pub fn appendCodepoints(seq: Sequence, allocator: Allocator, list: *CodepointList) !void {
        var iter = std.mem.splitScalar(u8, seq.slice, ' ');
        while (iter.next()) |tok| {
            if (tok.len == 0) continue;
            const codepoint = std.fmt.parseInt(u21, tok, 16) catch {
                return error.TokenProblem;
            };
            try list.append(allocator, codepoint);
        }
    }
};

pub const LabelSet = struct {
    slice: []const u8,

    pub fn iterator(ls: *LabelSet) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, ls.slice, ' ');
    }

    pub fn value(set: LabelSet) []const u8 {
        return set.slice;
    }
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

    pub fn format(str_map: *StringMap, _: []const u8, _: FmtOps, writer: anytype) !void {
        var iter = str_map.iterator();
        while (iter.next()) |entry| {
            try writer.print("pub const {s} = {f};\n\n", .{ entry.key_ptr.*, esc_string(entry.value_ptr.items) });
        }
    }
};

pub const CodepointMap = struct {
    allocator: Allocator,
    map: CodepointHash = .empty,

    pub fn get(cp_map: *CodepointMap, key: []const u8) !*CodepointList {
        if (cp_map.map.getPtr(key)) |ptr| {
            return ptr;
        }
        const key_clone = try cp_map.allocator.dupe(u8, key);
        const new_map: CodepointList = .empty;
        try cp_map.map.put(cp_map.allocator, key_clone, new_map);
        return cp_map.map.getPtr(key).?;
    }
};

pub fn writeCodepointArray(writer: anytype, name: []const u8, codepoints: []const u21) !void {
    try writer.print("pub const {s}: [{d}]u21 = .{{ ", .{ name, codepoints.len });
    for (codepoints) |codepoint| {
        try writer.print("0x{X}, ", .{codepoint});
    }
    try writer.writeAll("};\n");
}

const Alias = union(enum) {
    alias: []const u8,
    aliases: [][]const u8,
};

pub fn propertyMap(allocator: Allocator) !PropertyMap {
    var prop_map: PropertyMap = .empty;
    var this_property: []const u8 = "";
    var alias_map: *AliasMap = undefined;
    {
        var in_file = try std.fs.cwd().openFile("UCD/PropertyValueAliases.txt", .{});
        defer in_file.close();
        var in_buf: [4096]u8 = undefined;
        const in_reader = in_file.reader(&in_buf);
        var line_iter: LineIterator(@TypeOf(in_reader)) = .{ .read = in_reader };
        scan: while (try line_iter.next()) |tok_iter_const| {
            var tok_iter = tok_iter_const;
            const prop_name = tok_iter.next().?;
            switch (prop_name) {
                .label => |l| {
                    // Skip classes with numeric data (for now at least)
                    const property = l.value();
                    if (std.mem.eql(u8, "ccc", property) or
                        std.mem.eql(u8, "age", property)) continue :scan;

                    if (!std.mem.eql(u8, l.value(), this_property)) {
                        this_property = try allocator.dupe(u8, property);
                        try prop_map.put(allocator, this_property, .empty);
                        alias_map = prop_map.getPtr(this_property).?;
                    }
                    const short_name = try allocator.dupe(u8, tok_iter.next().?.label.value());
                    const long_token = tok_iter.next().?.label;
                    if (tok_iter.next()) |alias| {
                        const first_alias = try allocator.dupe(u8, long_token.value());
                        if (alias != .label) {
                            // There's one hyphenated alias and we don't need it.
                            if (alias == .hyphenated) {
                                const long_name = try allocator.dupe(u8, long_token.value());
                                try alias_map.put(allocator, short_name, .{ .alias = long_name });
                                continue :scan;
                            }

                            std.debug.panic("Unexpected {s} {any} on line {d}\n{s}\n", .{
                                @tagName(alias),
                                alias,
                                line_iter.line,
                                tok_iter.line,
                            });
                        }
                        const second_alias = try allocator.dupe(u8, alias.label.value());
                        var aliases_list: AliasesList = .empty;
                        try aliases_list.ensureTotalCapacity(allocator, 2);
                        aliases_list.appendAssumeCapacity(first_alias);
                        aliases_list.appendAssumeCapacity(second_alias);
                        while (tok_iter.next()) |next_token| {
                            const next_alias = try allocator.dupe(u8, next_token.label.value());
                            try aliases_list.append(allocator, next_alias);
                        }
                        const aliases = aliases_list.items;
                        try alias_map.put(allocator, short_name, .{ .aliases = aliases });
                    } else {
                        const long_name = try allocator.dupe(u8, long_token.value());
                        try alias_map.put(allocator, short_name, .{ .alias = long_name });
                    }
                },
                inline else => |_, tag| {
                    std.debug.panic("Invalid {s} at line {d}\n", .{ @tagName(tag), line_iter.line });
                },
            }
        }
    }
    return prop_map;
}

const std = @import("std");
const assert = std.debug.assert;
const TextList = std.ArrayListUnmanaged(u8);
const CodepointList = std.ArrayListUnmanaged(u21);
const AliasesList = std.ArrayListUnmanaged([]const u8);
const Allocator = std.mem.Allocator;
const StringHash = std.StringHashMapUnmanaged(TextList);
const CodepointHash = std.StringHashMapUnmanaged(CodepointList);
const FmtOps = std.fmt.FormatOptions;

const AliasMap = std.StringHashMapUnmanaged(Alias);

pub const PropertyMap = std.StringHashMapUnmanaged(AliasMap);

const esc_string = ezcaper.escStringExact;

const RuneSet = runeset.runeset.RuneSet;

pub const RuneMap = std.StringHashMapUnmanaged(RuneSet);
