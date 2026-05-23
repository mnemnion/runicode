/// Standard library pieces used for allocation, maps, and UTF-8 encoding.
const std = @import("std");
/// Test namespace is kept local so DB invariants can live next to the storage code.
const testing = std.testing;
/// Shared parsed range type used by the file readers and the emitter.
const parse = @import("parse.zig");
/// Runtime set type used when a caller already has a canonical Unicode set.
const RuneSet = @import("runeset").RuneSet;

/// One concrete property value, stored in all shapes the generator emits.
///
/// Keeping ranges, scalar codepoints, and concatenated WTF-8 bytes together is
/// memory-heavy, but it prevents every emitter from re-deriving its preferred
/// representation from scratch.
pub const PropertyValue = struct {
    /// Compact inclusive ranges as read from UCD, or reconstructed from a RuneSet.
    ///
    /// The set/codepoint/string emitters all use this shape as the stable source
    /// of truth for generated files.
    ranges: std.ArrayList(parse.Range) = .empty,

    /// Expanded scalar values for direct `[]const u21` output.
    ///
    /// This duplicates the ranges on purpose because generated codepoints files
    /// should not have to expand ranges at comptime.
    codepoints: std.ArrayList(u21) = .empty,

    /// Concatenated WTF-8 codepoint bytes for string and RuneSet construction.
    ///
    /// WTF-8 is used so surrogate property data remains representable even
    /// though it is not valid Unicode scalar UTF-8.
    utf8: std.ArrayList(u8) = .empty,

    /// Releases all owned buffers for a property value.
    ///
    /// Values are stored in unmanaged containers, so teardown must be explicit
    /// and use the same allocator that populated the lists.
    pub fn deinit(value: *PropertyValue, allocator: std.mem.Allocator) void {
        value.ranges.deinit(allocator);
        value.codepoints.deinit(allocator);
        value.utf8.deinit(allocator);
    }
};

/// All values for a single property namespace, such as `GeneralCategory`.
///
/// Names are owned by the group so parsed UCD line slices can be discarded as
/// soon as their fields have been copied into the database.
pub const PropertyGroup = struct {
    /// Allocator used for value names and every `PropertyValue` list in the group.
    allocator: std.mem.Allocator,

    /// Map from canonical value name to the generated representations for it.
    values: std.StringHashMapUnmanaged(PropertyValue) = .empty,

    /// Creates an empty property group bound to the caller's allocator.
    ///
    /// The group keeps the allocator because unmanaged maps/lists need it again
    /// during mutation and teardown.
    pub fn init(allocator: std.mem.Allocator) PropertyGroup {
        return .{ .allocator = allocator };
    }

    /// Releases every owned value name and value buffer in the group.
    ///
    /// This is separate from `Db.deinit` so groups remain responsible for their
    /// own nested storage.
    pub fn deinit(group: *PropertyGroup) void {
        var it = group.values.iterator();
        while (it.next()) |entry| {
            group.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(group.allocator);
        }
        group.values.deinit(group.allocator);
    }

    /// Finds an existing value by name without creating it.
    ///
    /// Readers use this to detect already-loaded data; aggregate synthesis uses
    /// it to avoid overwriting real UCD values with derived ones.
    pub fn value(group: *PropertyGroup, name: []const u8) ?*PropertyValue {
        return group.values.getPtr(name);
    }

    /// Finds or creates a value slot and takes ownership of the value name.
    ///
    /// The copy is required because callers often pass slices into transient
    /// input buffers.
    fn getOrPutValue(group: *PropertyGroup, name: []const u8) !*PropertyValue {
        const owned_name = try group.allocator.dupe(u8, name);
        errdefer group.allocator.free(owned_name);

        const result = try group.values.getOrPut(group.allocator, owned_name);
        if (result.found_existing) {
            group.allocator.free(owned_name);
        } else {
            result.value_ptr.* = .{};
        }
        return result.value_ptr;
    }
};

/// In-memory database of all property groups the generator will emit.
///
/// This is intentionally simple: the expensive normalization happens while data
/// is loaded so emission can walk plain maps and arrays.
pub const Db = struct {
    /// Allocator used for group names, groups, and all nested property values.
    allocator: std.mem.Allocator,

    /// Map from generated property namespace to its values.
    groups: std.StringHashMapUnmanaged(PropertyGroup) = .empty,

    /// Creates an empty Unicode property database.
    ///
    /// The allocator is kept so every nested unmanaged allocation has a common
    /// lifetime.
    pub fn init(allocator: std.mem.Allocator) Db {
        return .{ .allocator = allocator };
    }

    /// Releases every property group and owned group name.
    ///
    /// Group teardown handles the nested value storage.
    pub fn deinit(db: *Db) void {
        var it = db.groups.iterator();
        while (it.next()) |entry| {
            db.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        db.groups.deinit(db.allocator);
    }

    /// Finds a property group without creating it.
    ///
    /// This lets readers and synthesis passes distinguish absent input from an
    /// empty-but-valid property.
    pub fn property(db: *Db, name: []const u8) ?*PropertyGroup {
        return db.groups.getPtr(name);
    }

    /// Counts loaded property groups for the generator's status line.
    ///
    /// It is deliberately group-level only; value counts are noisy and less
    /// useful for spotting gross load failures.
    pub fn propertyCount(db: *const Db) usize {
        return db.groups.count();
    }

    /// Adds one inclusive range to a property value and expands its emitted forms.
    ///
    /// UCD files are range-oriented, while generated APIs expose ranges,
    /// codepoint arrays, and strings, so ingest pays the expansion cost once.
    pub fn addRange(db: *Db, property_name: []const u8, value_name: []const u8, range: parse.Range) !void {
        const group = try db.getOrPutProperty(property_name);
        const prop_value = try group.getOrPutValue(value_name);
        try prop_value.ranges.append(db.allocator, range);

        var codepoint = range.first;
        while (codepoint <= range.last) : (codepoint += 1) {
            try prop_value.codepoints.append(db.allocator, codepoint);

            var buf: [4]u8 = undefined;
            const len = try wtf8Encode(codepoint, &buf);
            try prop_value.utf8.appendSlice(db.allocator, buf[0..len]);
        }
    }

    /// Adds a complete RuneSet to a property value in one ordered pass.
    ///
    /// Aggregate properties are cheaper to build as RuneSet unions than by
    /// replaying many source ranges; this method turns the final set back into
    /// the DB's normal ranges/codepoints/WTF-8 representation.
    pub fn addRuneSet(db: *Db, property_name: []const u8, value_name: []const u8, rune_set: RuneSet) !void {
        // The property group provides the namespace that emitted files mirror.
        const group = try db.getOrPutProperty(property_name);

        // The property value is where all three generated representations are
        // accumulated together so they cannot drift apart.
        const prop_value = try group.getOrPutValue(value_name);

        // RuneSet iteration is sorted, so adjacent decoded codepoints can be
        // folded into compact ranges while we append the expanded forms.
        var pending_range: ?parse.Range = null;
        var iter = rune_set.iterateRunes();
        while (iter.next()) |rune| {
            // Decode the iterator's WTF-8 slice once so range compaction and
            // codepoint output use the same scalar value.
            const codepoint = try wtf8Decode(rune);
            try prop_value.codepoints.append(db.allocator, codepoint);
            try prop_value.utf8.appendSlice(db.allocator, rune);

            if (pending_range) |*range| {
                if (range.last != std.math.maxInt(u21) and range.last + 1 == codepoint) {
                    range.last = codepoint;
                } else {
                    try prop_value.ranges.append(db.allocator, range.*);
                    pending_range = .{ .first = codepoint, .last = codepoint };
                }
            } else {
                pending_range = .{ .first = codepoint, .last = codepoint };
            }
        }
        if (pending_range) |range| try prop_value.ranges.append(db.allocator, range);
    }

    /// Finds or creates a property group and takes ownership of the group name.
    ///
    /// Like value names, group names arrive as transient slices from parsers and
    /// manifests, so the database must keep its own copy.
    fn getOrPutProperty(db: *Db, name: []const u8) !*PropertyGroup {
        const owned_name = try db.allocator.dupe(u8, name);
        errdefer db.allocator.free(owned_name);

        const result = try db.groups.getOrPut(db.allocator, owned_name);
        if (result.found_existing) {
            db.allocator.free(owned_name);
        } else {
            result.value_ptr.* = PropertyGroup.init(db.allocator);
        }
        return result.value_ptr;
    }
};

/// Encodes a codepoint as WTF-8 bytes.
///
/// Unicode property data includes surrogate codepoints, so strict UTF-8 is not
/// enough for the generator's internal string representation.
fn wtf8Encode(codepoint: u21, buf: []u8) !usize {
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
        if (buf.len < 3) return error.NoSpaceLeft;
        buf[0] = 0xE0 | @as(u8, @intCast(codepoint >> 12));
        buf[1] = 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3F));
        buf[2] = 0x80 | @as(u8, @intCast(codepoint & 0x3F));
        return 3;
    }
    const len = std.unicode.utf8Encode(codepoint, buf) catch |err| switch (err) {
        error.Utf8CannotEncodeSurrogateHalf => unreachable,
        error.CodepointTooLarge => return err,
    };
    return @intCast(len);
}

/// Decodes one WTF-8 rune yielded by `RuneSet.iterateRunes`.
///
/// This mirrors `wtf8Encode` so RuneSet-backed aggregates can be converted back
/// into scalar codepoints, including surrogate codepoints.
fn wtf8Decode(bytes: []const u8) !u21 {
    if (bytes.len == 0) return error.InvalidWtf8;

    // The leading byte determines the sequence width; continuation bytes are
    // validated before their payload bits are folded into the codepoint.
    const first = bytes[0];
    if (first <= 0x7F) return first;
    if (first >= 0xC0 and first <= 0xDF) {
        if (bytes.len < 2 or !isFollowByte(bytes[1])) return error.InvalidWtf8;
        return (@as(u21, first & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F);
    }
    if (first >= 0xE0 and first <= 0xEF) {
        if (bytes.len < 3 or !isFollowByte(bytes[1]) or !isFollowByte(bytes[2])) return error.InvalidWtf8;
        return (@as(u21, first & 0x0F) << 12) |
            (@as(u21, bytes[1] & 0x3F) << 6) |
            @as(u21, bytes[2] & 0x3F);
    }
    if (first >= 0xF0 and first <= 0xF7) {
        if (bytes.len < 4 or !isFollowByte(bytes[1]) or !isFollowByte(bytes[2]) or !isFollowByte(bytes[3])) return error.InvalidWtf8;
        return (@as(u21, first & 0x07) << 18) |
            (@as(u21, bytes[1] & 0x3F) << 12) |
            (@as(u21, bytes[2] & 0x3F) << 6) |
            @as(u21, bytes[3] & 0x3F);
    }
    return error.InvalidWtf8;
}

/// Returns whether a byte is a WTF-8/UTF-8 continuation byte.
///
/// The decoder checks this explicitly so malformed internal byte slices fail
/// locally instead of being mis-decoded into bad codepoints.
fn isFollowByte(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xBF;
}

test "property group accumulates range as codepoints and utf8" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x43 });

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Lu").?;
    try testing.expectEqualSlices(u21, &.{ 0x41, 0x42, 0x43 }, value.codepoints.items);
    try testing.expectEqualStrings("ABC", value.utf8.items);
}

test "surrogate codepoints encode as WTF-8 bytes" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Cs", .{ .first = 0xD800, .last = 0xD800 });

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Cs").?;
    try testing.expectEqualSlices(u21, &.{0xD800}, value.codepoints.items);
    try testing.expectEqualSlices(u8, &.{ 0xED, 0xA0, 0x80 }, value.utf8.items);
}

test "property group accumulates runeset as compact ranges and utf8" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    const rune_set = try RuneSet.createFromConstString("ABCX", testing.allocator);
    defer rune_set.deinit(testing.allocator);

    try db.addRuneSet("GeneralCategory", "Letter", rune_set);

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Letter").?;
    try testing.expectEqualSlices(parse.Range, &.{
        .{ .first = 0x41, .last = 0x43 },
        .{ .first = 0x58, .last = 0x58 },
    }, value.ranges.items);
    try testing.expectEqualSlices(u21, &.{ 0x41, 0x42, 0x43, 0x58 }, value.codepoints.items);
    try testing.expectEqualStrings("ABCX", value.utf8.items);
}
