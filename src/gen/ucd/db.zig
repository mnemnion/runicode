/// Standard library pieces used for allocation and maps.
const std = @import("std");
/// Test namespace is kept local so DB invariants can live next to the storage code.
const testing = std.testing;
/// WTF-8 encode/decode belongs to unicoder, not this generator.
const unicoder = @import("unicoder");
/// Shared parsed range type used by the file readers and the emitter.
const parse = @import("parse.zig");
/// Runtime set type retained by the DB for generated set/string/codepoint leaves.
const RuneSet = @import("runeset").RuneSet;

/// One concrete property value.
///
/// Ranges preserve the UCD source shape for copying and diagnostics. `rune_set`
/// is the normalized data used by emitters.
pub const PropertyValue = struct {
    /// Compact inclusive ranges as read from UCD, or reconstructed from a RuneSet.
    ranges: std.ArrayList(parse.Range) = .empty,

    /// Normalized set for this property value. It is optional only because map
    /// slots are default-initialized before the first range is inserted.
    rune_set: ?RuneSet = null,

    /// Releases all owned buffers for a property value.
    ///
    /// Values are stored in unmanaged containers, so teardown must be explicit
    /// and use the same allocator that populated the lists.
    pub fn deinit(value: *PropertyValue, allocator: std.mem.Allocator) void {
        value.ranges.deinit(allocator);
        if (value.rune_set) |set| set.deinit(allocator);
    }

    /// Takes ownership of `owned_set` and unions it into this value's RuneSet.
    fn addOwnedRuneSet(value: *PropertyValue, allocator: std.mem.Allocator, owned_set: RuneSet) !void {
        if (value.rune_set) |current_set| {
            errdefer owned_set.deinit(allocator);
            const union_set = try current_set.setUnion(owned_set, allocator);
            current_set.deinit(allocator);
            owned_set.deinit(allocator);
            value.rune_set = union_set;
        } else {
            value.rune_set = owned_set;
        }
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
/// This is intentionally simple: the expensive RuneSet normalization happens
/// while data is loaded so emission can walk plain maps.
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

    /// Adds one inclusive range to a property value and merges it into the
    /// value's retained RuneSet.
    pub fn addRange(db: *Db, property_name: []const u8, value_name: []const u8, range: parse.Range) !void {
        const group = try db.getOrPutProperty(property_name);
        const prop_value = try group.getOrPutValue(value_name);

        const range_set = try createRuneSetFromRanges(&.{range}, db.allocator);
        const old_ranges_len = prop_value.ranges.items.len;
        try prop_value.ranges.append(db.allocator, range);
        errdefer prop_value.ranges.shrinkRetainingCapacity(old_ranges_len);
        try prop_value.addOwnedRuneSet(db.allocator, range_set);
    }

    /// Adds a complete RuneSet to a property value.
    ///
    /// Aggregate properties are cheaper to build as RuneSet unions than by
    /// replaying many source ranges. This stores both the compact ranges rebuilt
    /// from the set and a cloned RuneSet owned by the database.
    pub fn addRuneSet(db: *Db, property_name: []const u8, value_name: []const u8, rune_set: RuneSet) !void {
        const group = try db.getOrPutProperty(property_name);
        const prop_value = try group.getOrPutValue(value_name);

        var compact_ranges = try rangesFromRuneSet(db.allocator, rune_set);
        defer compact_ranges.deinit(db.allocator);
        const old_ranges_len = prop_value.ranges.items.len;
        try prop_value.ranges.appendSlice(db.allocator, compact_ranges.items);
        errdefer prop_value.ranges.shrinkRetainingCapacity(old_ranges_len);

        try prop_value.addOwnedRuneSet(db.allocator, try cloneRuneSet(db.allocator, rune_set));
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

/// Clones a RuneSet body so the database owns its stored set.
fn cloneRuneSet(allocator: std.mem.Allocator, rune_set: RuneSet) !RuneSet {
    return .{ .body = try allocator.dupe(u64, rune_set.body) };
}

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

    const mutable = try bytes.toOwnedSlice(allocator);
    defer allocator.free(mutable);
    return try RuneSet.createFromMutableString(mutable, allocator);
}

/// Rebuilds compact ranges from RuneSet's sorted iteration order.
fn rangesFromRuneSet(allocator: std.mem.Allocator, rune_set: RuneSet) !std.ArrayList(parse.Range) {
    var ranges: std.ArrayList(parse.Range) = .empty;
    errdefer ranges.deinit(allocator);

    var pending_range: ?parse.Range = null;
    var iter = rune_set.iterateRunes();
    while (iter.next()) |rune| {
        const codepoint = codepointFromRune(rune);
        if (pending_range) |*range| {
            if (range.last != std.math.maxInt(u21) and range.last + 1 == codepoint) {
                range.last = codepoint;
            } else {
                try ranges.append(allocator, range.*);
                pending_range = .{ .first = codepoint, .last = codepoint };
            }
        } else {
            pending_range = .{ .first = codepoint, .last = codepoint };
        }
    }
    if (pending_range) |range| try ranges.append(allocator, range);
    return ranges;
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

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Lu").?;
    try testing.expectEqualSlices(parse.Range, &.{.{ .first = 0x41, .last = 0x43 }}, value.ranges.items);
    try expectRuneSetCodepoints(&.{ 0x41, 0x42, 0x43 }, value.rune_set.?);
}

test "surrogate codepoints are retained in the runeset" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Cs", .{ .first = 0xD800, .last = 0xD800 });

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Cs").?;
    try expectRuneSetCodepoints(&.{0xD800}, value.rune_set.?);
}

test "property group accumulates runeset as compact ranges and stored runeset" {
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
    try expectRuneSetCodepoints(&.{ 0x41, 0x42, 0x43, 0x58 }, value.rune_set.?);
}
