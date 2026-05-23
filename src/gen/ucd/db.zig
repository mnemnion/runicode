/// Standard library pieces used for allocation and maps.
const std = @import("std");
/// Test namespace is kept local so DB invariants can live next to the storage code.
const testing = std.testing;
/// WTF-8 encode/decode belongs to unicoder, not this generator.
const unicoder = @import("unicoder");
/// Shared parsed range type used by the file readers and the emitter.
const parse = @import("parse.zig");
/// Runtime set type built once per value after all ranges are loaded.
const RuneSet = @import("runeset").RuneSet;

/// One concrete property value.
///
/// Ranges preserve the UCD source shape while loading. `rune_set` is filled by
/// `Db.finalizeRuneSets` before emission.
pub const PropertyValue = struct {
    /// Compact inclusive ranges as read from UCD or derived aggregate sources.
    ranges: std.ArrayList(parse.Range) = .empty,

    /// Normalized set for this property value.
    rune_set: ?RuneSet = null,

    /// Releases all owned buffers for a property value.
    ///
    /// Values are stored in unmanaged containers, so teardown must be explicit
    /// and use the same allocator that populated the lists.
    pub fn deinit(value: *PropertyValue, allocator: std.mem.Allocator) void {
        value.ranges.deinit(allocator);
        if (value.rune_set) |set| set.deinit(allocator);
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
/// This is intentionally simple: readers append ranges, then a finalization pass
/// builds the RuneSets consumed by emission.
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

    /// Adds one inclusive range to a property value.
    pub fn addRange(db: *Db, property_name: []const u8, value_name: []const u8, range: parse.Range) !void {
        try db.addRanges(property_name, value_name, &.{range});
    }

    /// Adds inclusive ranges to a property value.
    pub fn addRanges(db: *Db, property_name: []const u8, value_name: []const u8, ranges: []const parse.Range) !void {
        if (ranges.len == 0) return error.EmptyRangeSet;

        const group = try db.getOrPutProperty(property_name);
        const prop_value = try group.getOrPutValue(value_name);
        try prop_value.ranges.appendSlice(db.allocator, ranges);
    }

    /// Builds exactly one retained RuneSet for every loaded property value.
    pub fn finalizeRuneSets(db: *Db) !void {
        var group_it = db.groups.iterator();
        while (group_it.next()) |group_entry| {
            var value_it = group_entry.value_ptr.values.iterator();
            while (value_it.next()) |value_entry| {
                const value = value_entry.value_ptr;
                if (value.rune_set != null) return error.RuneSetAlreadyFinalized;
                if (value.ranges.items.len == 0) return error.EmptyRangeSet;
                value.rune_set = try createRuneSetFromRanges(value.ranges.items, db.allocator);
            }
        }
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

/// Expands ranges to WTF-8 and constructs a RuneSet from the mutable scratch
/// buffer.
fn createRuneSetFromRanges(ranges: []const parse.Range, allocator: std.mem.Allocator) !RuneSet {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    for (ranges) |range| {
        var codepoint = range.first;
        while (codepoint <= range.last) : (codepoint += 1) {
            var buf: [4]u8 = undefined;
            const len = try unicoder.codepoint.toWtf8(codepoint, &buf);
            try bytes.appendSlice(allocator, buf[0..len]);
        }
    }

    return try RuneSet.createFromMutableString(bytes.items, allocator);
}

/// Decodes the single WTF-8 rune slice yielded by RuneSet iteration.
fn codepointFromRune(rune: []const u8) u21 {
    var codepoints = unicoder.wtf8.iterator(rune, .assume_valid);
    const codepoint = codepoints.nextCodepoint().?;
    std.debug.assert(codepoints.nextCodepoint() == null);
    return codepoint;
}

fn expectRuneSetCodepoints(expected: []const u21, rune_set: RuneSet) !void {
    var actual: std.ArrayList(u21) = .empty;
    defer actual.deinit(testing.allocator);

    var iter = rune_set.iterateRunes();
    while (iter.next()) |rune| {
        try actual.append(testing.allocator, codepointFromRune(rune));
    }
    try testing.expectEqualSlices(u21, expected, actual.items);
}

test "property group accumulates range as ranges and runeset" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x43 });
    try db.finalizeRuneSets();

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Lu").?;
    try testing.expectEqualSlices(parse.Range, &.{.{ .first = 0x41, .last = 0x43 }}, value.ranges.items);
    try expectRuneSetCodepoints(&.{ 0x41, 0x42, 0x43 }, value.rune_set.?);
}

test "surrogate codepoints are retained in the runeset" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Cs", .{ .first = 0xD800, .last = 0xD800 });
    try db.finalizeRuneSets();

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Cs").?;
    try expectRuneSetCodepoints(&.{0xD800}, value.rune_set.?);
}
