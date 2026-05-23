const std = @import("std");
const testing = std.testing;

pub const FileKind = enum {
    codepoint_property,
    one_field_set,
    script_extensions,
    property_aliases,
    property_value_aliases,
    derived_normalization_props,
    unicode_data,
    bidi_brackets,
    bidi_mirroring,
    case_folding,
    special_casing,
    scalar_map,
    sequence_map,
    records,
    known_skip,
};

pub const UcdFile = struct {
    path: []const u8,
    kind: FileKind,
    property: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const known_files = [_]UcdFile{
    .{ .path = "ArabicShaping.txt", .kind = .known_skip, .reason = "covered by extracted joining property files" },
    .{ .path = "BidiBrackets.txt", .kind = .bidi_brackets, .property = "bpt", .namespace = "BidiBrackets" },
    .{ .path = "BidiCharacterTest.txt", .kind = .known_skip, .reason = "conformance test" },
    .{ .path = "BidiMirroring.txt", .kind = .bidi_mirroring, .property = "bmg", .namespace = "BidiMirroring" },
    .{ .path = "BidiTest.txt", .kind = .known_skip, .reason = "conformance test" },
    .{ .path = "Blocks.txt", .kind = .codepoint_property, .property = "blk", .namespace = "Blocks" },
    .{ .path = "CJKRadicals.txt", .kind = .known_skip, .reason = "catalog data outside current public structures" },
    .{ .path = "CaseFolding.txt", .kind = .case_folding, .property = "cf", .namespace = "CaseFolding" },
    .{ .path = "CompositionExclusions.txt", .kind = .one_field_set, .property = "CE", .namespace = "CompositionExclusion" },
    .{ .path = "DerivedAge.txt", .kind = .codepoint_property, .property = "age", .namespace = "Age" },
    .{ .path = "DerivedCoreProperties.txt", .kind = .codepoint_property, .namespace = "CoreProperties" },
    .{ .path = "DerivedNormalizationProps.txt", .kind = .derived_normalization_props, .namespace = "Normalization" },
    .{ .path = "DoNotEmit.txt", .kind = .known_skip, .reason = "advisory rendering data" },
    .{ .path = "EastAsianWidth.txt", .kind = .codepoint_property, .property = "ea", .namespace = "EastAsianWidth" },
    .{ .path = "EmojiSources.txt", .kind = .known_skip, .reason = "historical carrier mapping data" },
    .{ .path = "EquivalentUnifiedIdeograph.txt", .kind = .scalar_map, .property = "EqUIdeo", .namespace = "EquivalentUnifiedIdeograph" },
    .{ .path = "HangulSyllableType.txt", .kind = .codepoint_property, .property = "hst", .namespace = "HangulSyllableType" },
    .{ .path = "Index.txt", .kind = .known_skip, .reason = "human index data" },
    .{ .path = "IndicPositionalCategory.txt", .kind = .codepoint_property, .property = "InPC", .namespace = "IndicPositionalCategory" },
    .{ .path = "IndicSyllabicCategory.txt", .kind = .codepoint_property, .property = "InSC", .namespace = "IndicSyllabicCategory" },
    .{ .path = "Jamo.txt", .kind = .scalar_map, .property = "JSN", .namespace = "Jamo" },
    .{ .path = "LineBreak.txt", .kind = .codepoint_property, .property = "lb", .namespace = "LineBreak" },
    .{ .path = "NameAliases.txt", .kind = .records, .property = "Name_Alias", .namespace = "NameAliases" },
    .{ .path = "NamedSequences.txt", .kind = .sequence_map, .namespace = "NamedSequences" },
    .{ .path = "NamedSequencesProv.txt", .kind = .known_skip, .reason = "empty provisional named sequence file in bundled UCD" },
    .{ .path = "NamesList.html", .kind = .known_skip, .reason = "rendered reference document" },
    .{ .path = "NamesList.txt", .kind = .known_skip, .reason = "rendered reference document" },
    .{ .path = "NormalizationCorrections.txt", .kind = .records, .namespace = "NormalizationCorrections" },
    .{ .path = "NormalizationTest.txt", .kind = .known_skip, .reason = "conformance test" },
    .{ .path = "NushuSources.txt", .kind = .known_skip, .reason = "source catalog data" },
    .{ .path = "PropList.txt", .kind = .codepoint_property, .namespace = "CoreProperties" },
    .{ .path = "PropertyAliases.txt", .kind = .property_aliases, .namespace = "PropertyAliases" },
    .{ .path = "PropertyValueAliases.txt", .kind = .property_value_aliases, .namespace = "PropertyValueAliases" },
    .{ .path = "ReadMe.txt", .kind = .known_skip, .reason = "documentation" },
    .{ .path = "ScriptExtensions.txt", .kind = .script_extensions, .property = "scx", .namespace = "ScriptsExtended" },
    .{ .path = "Scripts.txt", .kind = .codepoint_property, .property = "sc", .namespace = "Scripts" },
    .{ .path = "SpecialCasing.txt", .kind = .special_casing, .namespace = "SpecialCasing" },
    .{ .path = "StandardizedVariants.txt", .kind = .records, .namespace = "StandardizedVariants" },
    .{ .path = "TangutSources.txt", .kind = .known_skip, .reason = "source catalog data" },
    .{ .path = "USourceData.txt", .kind = .known_skip, .reason = "U-source catalog data" },
    .{ .path = "USourceGlyphs.pdf", .kind = .known_skip, .reason = "rendered reference document" },
    .{ .path = "USourceRSChart.pdf", .kind = .known_skip, .reason = "rendered reference document" },
    .{ .path = "UnicodeData.txt", .kind = .unicode_data, .namespace = "UnicodeData" },
    .{ .path = "Unikemet.txt", .kind = .known_skip, .reason = "Egyptian hieroglyph catalog data" },
    .{ .path = "VerticalOrientation.txt", .kind = .codepoint_property, .property = "vo", .namespace = "VerticalOrientation" },
    .{ .path = "auxiliary/GraphemeBreakProperty.txt", .kind = .codepoint_property, .property = "GCB", .namespace = "GraphemeBreak" },
    .{ .path = "auxiliary/GraphemeBreakTest.html", .kind = .known_skip, .reason = "rendered conformance test" },
    .{ .path = "auxiliary/GraphemeBreakTest.txt", .kind = .known_skip, .reason = "conformance test" },
    .{ .path = "auxiliary/LineBreakTest.html", .kind = .known_skip, .reason = "rendered conformance test" },
    .{ .path = "auxiliary/LineBreakTest.txt", .kind = .known_skip, .reason = "conformance test" },
    .{ .path = "auxiliary/SentenceBreakProperty.txt", .kind = .codepoint_property, .property = "SB", .namespace = "SentenceBreak" },
    .{ .path = "auxiliary/SentenceBreakTest.html", .kind = .known_skip, .reason = "rendered conformance test" },
    .{ .path = "auxiliary/SentenceBreakTest.txt", .kind = .known_skip, .reason = "conformance test" },
    .{ .path = "auxiliary/WordBreakProperty.txt", .kind = .codepoint_property, .property = "WB", .namespace = "WordBreak" },
    .{ .path = "auxiliary/WordBreakTest.html", .kind = .known_skip, .reason = "rendered conformance test" },
    .{ .path = "auxiliary/WordBreakTest.txt", .kind = .known_skip, .reason = "conformance test" },
    .{ .path = "emoji/ReadMe.txt", .kind = .known_skip, .reason = "documentation" },
    .{ .path = "emoji/emoji-data.txt", .kind = .codepoint_property, .namespace = "CoreProperties" },
    .{ .path = "emoji/emoji-variation-sequences.txt", .kind = .records, .namespace = "EmojiVariationSequences" },
    .{ .path = "extracted/DerivedBidiClass.txt", .kind = .codepoint_property, .property = "bc", .namespace = "BidiClass" },
    .{ .path = "extracted/DerivedBinaryProperties.txt", .kind = .codepoint_property, .namespace = "BinaryProperties" },
    .{ .path = "extracted/DerivedCombiningClass.txt", .kind = .codepoint_property, .property = "ccc", .namespace = "CombiningClass" },
    .{ .path = "extracted/DerivedDecompositionType.txt", .kind = .codepoint_property, .property = "dt", .namespace = "DecompositionType" },
    .{ .path = "extracted/DerivedEastAsianWidth.txt", .kind = .codepoint_property, .property = "ea", .namespace = "DerivedEastAsianWidth" },
    .{ .path = "extracted/DerivedGeneralCategory.txt", .kind = .codepoint_property, .property = "gc", .namespace = "GeneralCategory" },
    .{ .path = "extracted/DerivedJoiningGroup.txt", .kind = .codepoint_property, .property = "jg", .namespace = "JoiningGroup" },
    .{ .path = "extracted/DerivedJoiningType.txt", .kind = .codepoint_property, .property = "jt", .namespace = "JoiningType" },
    .{ .path = "extracted/DerivedLineBreak.txt", .kind = .codepoint_property, .property = "lb", .namespace = "DerivedLineBreak" },
    .{ .path = "extracted/DerivedName.txt", .kind = .records, .property = "na", .namespace = "DerivedName" },
    .{ .path = "extracted/DerivedNumericType.txt", .kind = .codepoint_property, .property = "nt", .namespace = "NumericType" },
    .{ .path = "extracted/DerivedNumericValues.txt", .kind = .records, .property = "nv", .namespace = "NumericValues" },
};

pub fn entryFor(path: []const u8) ?UcdFile {
    for (known_files) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

test "manifest classifies representative UCD files" {
    try testing.expectEqual(FileKind.codepoint_property, entryFor("Blocks.txt").?.kind);
    try testing.expectEqual(FileKind.script_extensions, entryFor("ScriptExtensions.txt").?.kind);
    try testing.expectEqual(FileKind.case_folding, entryFor("CaseFolding.txt").?.kind);
    try testing.expectEqual(FileKind.known_skip, entryFor("BidiTest.txt").?.kind);
}

test "manifest paths are relative and unique" {
    for (known_files) |entry| {
        try testing.expect(!std.fs.path.isAbsolute(entry.path));
        try testing.expect(!std.mem.startsWith(u8, entry.path, "UCD/"));
    }

    for (known_files, 0..) |left, left_idx| {
        for (known_files[left_idx + 1 ..]) |right| {
            try testing.expect(!std.mem.eql(u8, left.path, right.path));
        }
    }
}
