const std = @import("std");
const runicode = @import("runicode");

test "generated roots expose property aliases" {
    try std.testing.expect(runicode.sets.gc.Lu.equalTo(runicode.sets.GeneralCategory.Lu));
    try std.testing.expect(runicode.sets.General_Category.Lu.equalTo(runicode.sets.GeneralCategory.Lu));
    try std.testing.expect(runicode.sets.scx.Latin.equalTo(runicode.sets.ScriptsExtended.Latin));
    try std.testing.expect(runicode.sets.gbp.Control.equalTo(runicode.sets.GraphemeBreak.Control));
    try std.testing.expect(runicode.sets.Grapheme_Break_Property.Control.equalTo(runicode.sets.GraphemeBreak.Control));
}

test "Supremum is generated as a set excluding Cn Co and Cs" {
    try std.testing.expect(runicode.sets.GeneralCategory.Lu.subsetOf(runicode.sets.Supremum));

    try expectDisjoint(runicode.sets.Supremum, runicode.sets.GeneralCategory.Unassigned);
    try expectDisjoint(runicode.sets.Supremum, runicode.sets.GeneralCategory.Private_Use);
    try expectDisjoint(runicode.sets.Supremum, runicode.sets.GeneralCategory.Surrogate);
}

test "kind-specific named maps resolve generated property maps with loose matching" {
    const GeneralCategorySets = runicode.NamedSetMaps.get("gc").?;
    var general_category_sets = GeneralCategorySets{};
    try std.testing.expect((general_category_sets.get("Lu") orelse unreachable).equalTo(runicode.sets.GeneralCategory.Lu));

    const ScriptExtensionSets = runicode.NamedSetMaps.get("Script Extensions").?;
    var script_extension_sets = ScriptExtensionSets{};
    try std.testing.expect((script_extension_sets.get("Latn") orelse unreachable).equalTo(runicode.sets.ScriptsExtended.Latin));

    const GraphemeBreakSets = runicode.NamedSetMaps.get("Grapheme Break Property").?;
    var grapheme_break_sets = GraphemeBreakSets{};
    try std.testing.expect((grapheme_break_sets.get("CN") orelse unreachable).equalTo(runicode.sets.GraphemeBreak.Control));

    const GeneralCategoryCodepoints = runicode.NamedCodepointMaps.get("gc").?;
    var general_category_codepoints = GeneralCategoryCodepoints{};
    try std.testing.expectEqualSlices(u21, &runicode.codepoints.GeneralCategory.Lu, general_category_codepoints.get("Uppercase Letter") orelse unreachable);

    const GraphemeBreakStrings = runicode.NamedStringMaps.get("Grapheme Break Property").?;
    var grapheme_break_strings = GraphemeBreakStrings{};
    try std.testing.expectEqualStrings(runicode.strs.GraphemeBreak.Control, grapheme_break_strings.get("CN") orelse unreachable);
}

fn expectDisjoint(left: anytype, right: anytype) !void {
    const intersection = try left.setIntersection(right, std.testing.allocator);
    defer intersection.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), intersection.runeCount());
}
