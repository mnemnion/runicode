const std = @import("std");
const testing = std.testing;

/// Unicode property data as RuneSet values.
pub const sets = struct {
    /// Unicode block sets.
    pub const Blocks = @import("sets/Blocks.zig");
    /// Unicode core property sets.
    pub const CoreProperties = @import("sets/CoreProperties.zig");
    /// Unicode general category sets.
    pub const GeneralCategory = @import("sets/GeneralCategory.zig");
    /// Unicode script sets.
    pub const Scripts = @import("sets/Scripts.zig");
    /// Unicode script extension sets.
    pub const ScriptsExtended = @import("sets/ScriptsExtended.zig");
    /// All assigned, public, character codepoints.
    pub const supremum = @import("sets/supremum.zig");

    /// Loose-matching maps for Unicode RuneSet property namespaces.
    pub const map = struct {
        /// Loose-matching map for Unicode block sets.
        pub const Blocks = NamedMap(sets.Blocks);
        /// Loose-matching map for Unicode core property sets.
        pub const CoreProperties = NamedMap(sets.CoreProperties);
        /// Loose-matching map for Unicode general category sets.
        pub const GeneralCategory = NamedMap(sets.GeneralCategory);
        /// Loose-matching map for Unicode script sets.
        pub const Scripts = NamedMap(sets.Scripts);
        /// Loose-matching map for Unicode script extension sets.
        pub const ScriptsExtended = NamedMap(sets.ScriptsExtended);
    };
};

/// Unicode property data as sorted codepoint slices.
pub const codepoints = struct {
    /// Unicode block codepoints.
    pub const Blocks = @import("codepoints/Blocks.zig");
    /// Unicode core property codepoints.
    pub const CoreProperties = @import("codepoints/CoreProperties.zig");
    /// Unicode general category codepoints.
    pub const GeneralCategory = @import("codepoints/GeneralCategory.zig");
    /// Unicode script codepoints.
    pub const Scripts = @import("codepoints/Scripts.zig");
    /// Unicode script extension codepoints.
    pub const ScriptsExtended = @import("codepoints/ScriptsExtended.zig");
    /// All assigned, public, character codepoints.
    pub const supremum = @import("codepoints/supremum.zig");

    /// Loose-matching maps for Unicode codepoint property namespaces.
    pub const map = struct {
        /// Loose-matching map for Unicode block codepoints.
        pub const Blocks = NamedMap(codepoints.Blocks);
        /// Loose-matching map for Unicode core property codepoints.
        pub const CoreProperties = NamedMap(codepoints.CoreProperties);
        /// Loose-matching map for Unicode general category codepoints.
        pub const GeneralCategory = NamedMap(codepoints.GeneralCategory);
        /// Loose-matching map for Unicode script codepoints.
        pub const Scripts = NamedMap(codepoints.Scripts);
        /// Loose-matching map for Unicode script extension codepoints.
        pub const ScriptsExtended = NamedMap(codepoints.ScriptsExtended);
    };
};

/// Unicode property data as UTF-8 strings.
pub const strs = struct {
    /// Unicode block strings.
    pub const Blocks = @import("strs/Blocks.zig");
    /// Unicode core property strings.
    pub const CoreProperties = @import("strs/CoreProperties.zig");
    /// Unicode general category strings.
    pub const GeneralCategory = @import("strs/GeneralCategory.zig");
    /// Unicode script strings.
    pub const Scripts = @import("strs/Scripts.zig");
    /// Unicode script extension strings.
    pub const ScriptsExtended = @import("strs/ScriptsExtended.zig");
    /// All assigned, public, character codepoints.
    pub const supremum = @import("strs/supremum.zig");

    /// Loose-matching maps for Unicode string property namespaces.
    pub const map = struct {
        /// Loose-matching map for Unicode block strings.
        pub const Blocks = NamedMap(strs.Blocks);
        /// Loose-matching map for Unicode core property strings.
        pub const CoreProperties = NamedMap(strs.CoreProperties);
        /// Loose-matching map for Unicode general category strings.
        pub const GeneralCategory = NamedMap(strs.GeneralCategory);
        /// Loose-matching map for Unicode script strings.
        pub const Scripts = NamedMap(strs.Scripts);
        /// Loose-matching map for Unicode script extension strings.
        pub const ScriptsExtended = NamedMap(strs.ScriptsExtended);
    };
};

/// Unicode property enum types.
pub const enums = struct {
    /// Unicode block enum.
    pub const BlocksKind = @import("enums/Blocks.zig").BlocksKind;
    /// Unicode core property enum.
    pub const CorePropertyKind = @import("enums/CoreProperties.zig").CorePropertyKind;
    /// Unicode general category enum.
    pub const GeneralCategoryKind = @import("enums/GeneralCategory.zig").GeneralCategoryKind;
    /// Unicode script enum.
    pub const ScriptsKind = @import("enums/Scripts.zig").ScriptsKind;
    /// Unicode short script enum.
    pub const ShortScriptsKind = @import("enums/Scripts.zig").ShortScriptsKind;
};

/// Compile-time constructor for loose-matching property maps.
pub const NamedMap = @import("ucd-tools").NamedMap;

test "public root forwards generated namespaces" {
    try testing.expect(sets.GeneralCategory.Lu.equalTo(@import("sets/GeneralCategory.zig").Lu));
    try testing.expectEqualSlices(u21, &codepoints.GeneralCategory.Lu, &@import("codepoints/GeneralCategory.zig").Lu);
    try testing.expectEqualStrings(strs.GeneralCategory.Lu, @import("strs/GeneralCategory.zig").Lu);
    try testing.expectEqual(enums.GeneralCategoryKind.Lu, .Lu);
}

test "mapped namespaces expose instantiable property maps" {
    var set_map = sets.map.GeneralCategory{};
    try testing.expect((set_map.get("Uppercase Letter") orelse unreachable).equalTo(sets.GeneralCategory.Lu));

    var codepoint_map = codepoints.map.GeneralCategory{};
    try testing.expectEqualSlices(u21, &codepoints.GeneralCategory.Co, codepoint_map.get("is private-use") orelse unreachable);

    var str_map = strs.map.Scripts{};
    try testing.expectEqualStrings(strs.Scripts.Greek, str_map.get("is greek") orelse unreachable);
}
