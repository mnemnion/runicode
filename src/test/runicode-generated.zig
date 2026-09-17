const std = @import("std");
const runicode = @import("runicode");
const test_options = @import("test_options");

test "generated roots expose property aliases" {
    if (comptime !test_options.generate_sets) return;

    try std.testing.expect(runicode.sets.gc.Lu.equalTo(runicode.sets.GeneralCategory.Lu));
    try std.testing.expect(runicode.sets.General_Category.Lu.equalTo(runicode.sets.GeneralCategory.Lu));
    try std.testing.expect(runicode.sets.scx.Latin.equalTo(runicode.sets.ScriptsExtended.Latin));
    try std.testing.expect(runicode.sets.gbp.Control.equalTo(runicode.sets.GraphemeBreak.Control));
    try std.testing.expect(runicode.sets.Grapheme_Break_Property.Control.equalTo(runicode.sets.GraphemeBreak.Control));
}

test "Supremum is generated as a set excluding Cn Co and Cs" {
    if (comptime !test_options.generate_sets) return;

    try std.testing.expect(runicode.sets.GeneralCategory.Lu.subsetOf(runicode.sets.Supremum));

    try expectDisjoint(runicode.sets.Supremum, runicode.sets.GeneralCategory.Unassigned);
    try expectDisjoint(runicode.sets.Supremum, runicode.sets.GeneralCategory.Private_Use);
    try expectDisjoint(runicode.sets.Supremum, runicode.sets.GeneralCategory.Surrogate);
}

test "kind-specific named maps resolve generated property maps with loose matching" {
    if (comptime test_options.generate_sets) {
        const GeneralCategorySets = runicode.NamedSetMaps.get("gc").?;
        var general_category_sets = GeneralCategorySets{};
        try std.testing.expect((general_category_sets.get("Lu") orelse unreachable).equalTo(runicode.sets.GeneralCategory.Lu));

        const ScriptExtensionSets = runicode.NamedSetMaps.get("Script Extensions").?;
        var script_extension_sets = ScriptExtensionSets{};
        try std.testing.expect((script_extension_sets.get("Latn") orelse unreachable).equalTo(runicode.sets.ScriptsExtended.Latin));

        const GraphemeBreakSets = runicode.NamedSetMaps.get("Grapheme Break Property").?;
        var grapheme_break_sets = GraphemeBreakSets{};
        try std.testing.expect((grapheme_break_sets.get("CN") orelse unreachable).equalTo(runicode.sets.GraphemeBreak.Control));

        const WordBreakSets = runicode.NamedSetMaps.get("Word Break").?;
        var word_break_sets = WordBreakSets{};
        try std.testing.expect((word_break_sets.get("hebrewletter") orelse unreachable).equalTo(runicode.sets.WordBreak.Hebrew_Letter));
    }

    if (comptime test_options.generate_codepoints) {
        const GeneralCategoryCodepoints = runicode.NamedCodepointMaps.get("gc").?;
        var general_category_codepoints = GeneralCategoryCodepoints{};
        try std.testing.expectEqualSlices(u21, &runicode.codepoints.GeneralCategory.Lu, general_category_codepoints.get("Uppercase Letter") orelse unreachable);
    }

    if (comptime test_options.generate_strings) {
        const GraphemeBreakStrings = runicode.NamedStringMaps.get("Grapheme Break Property").?;
        var grapheme_break_strings = GraphemeBreakStrings{};
        try std.testing.expectEqualStrings(runicode.strs.GraphemeBreak.Control, grapheme_break_strings.get("CN") orelse unreachable);
    }
}

test "character names resolve through loose-matching fst" {
    if (comptime !test_options.generate_names) return;

    var names = runicode.CharacterNames{};
    try std.testing.expectEqual(@as(?u21, 0x002D), names.get("hyphen minus"));
    try std.testing.expectEqual(@as(?u21, 0x000A), names.get("line_feed"));
    try std.testing.expectEqual(@as(?u21, 0x4E00), names.get("CJK Unified Ideograph-4E00"));
    try std.testing.expectEqual(@as(?u21, 0x4E00), names.get("CJK Unified Ideograph4E00"));
    try std.testing.expectEqual(@as(?u21, 0x008E), names.get("SINGLESHIFT2"));
    try std.testing.expectEqual(@as(?u21, 0x0F60), names.get("TIBETAN LETTER-A"));
    try std.testing.expectEqual(@as(?u21, 0x0F68), names.get("TIBETAN LETTER A"));
    try std.testing.expectEqual(@as(?u21, 0x1180), names.get("HANGUL JUNGSEONG O-E"));
    try std.testing.expectEqual(@as(?u21, 0x116C), names.get("HANGUL JUNGSEONG OE"));
}

test "disabled generated views are absent from the public root" {
    try std.testing.expectEqual(test_options.generate_sets, @hasDecl(runicode, "sets"));
    try std.testing.expectEqual(test_options.generate_codepoints, @hasDecl(runicode, "codepoints"));
    try std.testing.expectEqual(test_options.generate_strings, @hasDecl(runicode, "strs"));
    try std.testing.expectEqual(
        test_options.generate_sets or test_options.generate_codepoints or test_options.generate_strings,
        @hasDecl(runicode, "maps"),
    );
    try std.testing.expect(@hasDecl(runicode, "NamedMap"));
    try std.testing.expect(@hasDecl(runicode, "NamedMaps"));
    try std.testing.expectEqual(test_options.generate_sets, @hasDecl(runicode, "NamedSetMaps"));
    try std.testing.expectEqual(test_options.generate_codepoints, @hasDecl(runicode, "NamedCodepointMaps"));
    try std.testing.expectEqual(test_options.generate_names, @hasDecl(runicode, "names"));
    try std.testing.expectEqual(test_options.generate_names, @hasDecl(runicode, "CharacterNames"));
    try std.testing.expectEqual(test_options.generate_names, @hasDecl(runicode, "NamedCodepoints"));
    try std.testing.expectEqual(test_options.generate_strings, @hasDecl(runicode, "NamedStringMaps"));
}

test "explicit normalization bracket and Unikemet sets reach every enabled view" {
    if (comptime test_options.generate_sets) {
        try std.testing.expect(runicode.sets.Normalization.Composition_Exclusion.subsetOf(runicode.sets.Normalization.Full_Composition_Exclusion));
        try std.testing.expect(runicode.sets.NFC_QC.No.equalTo(runicode.sets.NFC_Quick_Check.N));
        try expectDisjoint(runicode.sets.NFC_QC.No, runicode.sets.NFC_QC.Maybe);
        try expectDisjoint(runicode.sets.bpt.Open, runicode.sets.bpt.Close);
        try std.testing.expectEqual(@as(usize, 4402), runicode.sets.Unikemet.Core.runeCount());
        try std.testing.expectEqual(@as(usize, 97), runicode.sets.Unikemet.Legacy.runeCount());
        try std.testing.expectEqual(@as(usize, 4), runicode.sets.Unikemet.kEH_NoMirror.runeCount());
        try std.testing.expectEqual(@as(usize, 44), runicode.sets.Unikemet.kEH_NoRotate.runeCount());
        inline for (.{ "NFC_QC", "NFD_QC", "NFKC_QC", "NFKD_QC" }) |property| {
            try std.testing.expect(!@hasDecl(@field(runicode.sets, property), "Yes"));
            try std.testing.expect(!@hasDecl(@field(runicode.sets, property), "Y"));
        }
        try std.testing.expect(!@hasDecl(runicode.sets.bpt, "None"));
        try std.testing.expect(!@hasDecl(runicode.sets.Unikemet, "None"));
        const Brackets = runicode.NamedSetMaps.get("bpt").?;
        var brackets = Brackets{};
        try std.testing.expect(brackets.get("o").?.equalTo(runicode.sets.bpt.Open));
    }
    if (comptime test_options.generate_codepoints) {
        try std.testing.expectEqual(@as(u21, 0x28), runicode.codepoints.bpt.Open[0]);
        try std.testing.expectEqual(@as(usize, 4), runicode.codepoints.Unikemet.kEH_NoMirror.len);
        try std.testing.expect(runicode.codepoints.NFC_QC.Maybe.len > 0);
    }
    if (comptime test_options.generate_strings) {
        try std.testing.expect(std.mem.startsWith(u8, runicode.strs.bpt.Open, "("));
        try std.testing.expect(runicode.strs.Unikemet.Core.len > 0);
        try std.testing.expect(runicode.strs.NFC_QC.Maybe.len > 0);
    }
}

fn expectDisjoint(left: anytype, right: anytype) !void {
    const intersection = try left.setIntersection(right, std.testing.allocator);
    defer intersection.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), intersection.runeCount());
}
