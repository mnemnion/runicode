# Runicode Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace checked-in generated Unicode data with a single build-time generator that audits and processes the bundled UCD tree.

**Architecture:** Keep `src/runicode.zig` as a checked-in facade and generate the data roots it imports. Build one host generator executable, pass it the bundled `UCD/` directory plus generated output paths, and create build modules from those generated files. The generator is manifest-driven: every UCD file is explicitly classified as generated, special, or skipped, and unknown files fail ordinary builds.

**Tech Stack:** Zig 0.16.0, `std.Build` generated file APIs, existing `runeset`, `unicoder`, `ezcaper`, and current `src/gen/ucd-tools.zig` helpers.

---

## File Structure

- Create `src/gen/runicode-gen.zig`: host executable entry point. Reads arguments, audits UCD, loads aliases, processes manifest entries, and emits generated roots.
- Create `src/gen/ucd/manifest.zig`: known UCD file manifest, file kinds, property metadata, and manifest tests.
- Create `src/gen/ucd/audit.zig`: UCD directory walker that rejects files missing from the manifest.
- Create `src/gen/ucd/parse.zig`: reusable parsers for UCD scalar ranges, scalar sequences, semicolon fields, and comments.
- Create `src/gen/ucd/aliases.zig`: property and property-value alias loading from `PropertyAliases.txt` and `PropertyValueAliases.txt`.
- Create `src/gen/ucd/db.zig`: in-memory database for property groups, string/codepoint data, aliases, enums, and special records.
- Create `src/gen/ucd/emit.zig`: generated Zig writer for `sets`, `codepoints`, `strs`, `enums`, maps, and special roots.
- Create `src/gen/ucd/special.zig`: handlers for `ScriptExtensions.txt`, one-field sets, map files, mixed normalization data, and special records.
- Modify `build.zig`: replace separate generator steps with one host generator and generated module roots.
- Modify `src/runicode.zig`: keep public names, forward them to generated module imports.
- Modify `build.zig.zon`: keep `UCD` in package paths.
- Eventually remove checked-in generated data under `src/sets`, `src/codepoints`, `src/strs`, and `src/enums` after generated roots pass tests.

## Implementation Tasks

### Task 1: Manifest And Audit Spine

**Files:**
- Create: `src/gen/ucd/manifest.zig`
- Create: `src/gen/ucd/audit.zig`
- Create: `src/gen/runicode-gen.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write manifest tests**

Add tests to `src/gen/ucd/manifest.zig` that verify representative files are classified and every manifest path is normalized:

```zig
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
```

- [ ] **Step 2: Run manifest tests and confirm failure**

Run: `zig test src/gen/ucd/manifest.zig`

Expected: fail because `src/gen/ucd/manifest.zig` does not exist.

- [ ] **Step 3: Implement manifest types and complete local UCD table**

Create `src/gen/ucd/manifest.zig` with:

```zig
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
    .{ .path = "PropList.txt", .kind = .codepoint_property, .namespace = "Properties" },
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
    .{ .path = "emoji/emoji-data.txt", .kind = .codepoint_property, .namespace = "Emoji" },
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
```

- [ ] **Step 4: Run manifest tests and confirm pass**

Run: `zig test src/gen/ucd/manifest.zig`

Expected: pass.

- [ ] **Step 5: Write audit tests**

Add tests in `src/gen/ucd/audit.zig` using `std.testing.tmpDir`:

```zig
test "audit rejects unknown UCD file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "Blocks.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "NewUnicodeThing.txt", .data = "" });
    try testing.expectError(error.UnknownUcdFile, auditDir(testing.allocator, tmp.dir));
}

test "audit accepts known nested UCD file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("auxiliary");
    try tmp.dir.writeFile(.{ .sub_path = "auxiliary/WordBreakProperty.txt", .data = "" });
    try auditDir(testing.allocator, tmp.dir);
}
```

- [ ] **Step 6: Implement audit walker**

Create `src/gen/ucd/audit.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const manifest = @import("manifest.zig");

pub const AuditError = error{UnknownUcdFile};

pub fn auditDir(allocator: std.mem.Allocator, dir: std.fs.Dir) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, std.fs.path.basename(entry.path), ".DS_Store")) continue;
        if (manifest.entryFor(entry.path) == null) {
            std.log.err("unknown UCD file: {s}", .{entry.path});
            return error.UnknownUcdFile;
        }
    }
}
```

- [ ] **Step 7: Run audit tests**

Run: `zig test src/gen/ucd/audit.zig`

Expected: pass.

- [ ] **Step 8: Add an audit-only generator executable**

Create `src/gen/runicode-gen.zig`:

```zig
const std = @import("std");
const audit = @import("ucd/audit.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len < 2) return error.InvalidArguments;

    var ucd_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer ucd_dir.close(io);

    try audit.auditDir(allocator, ucd_dir);
    std.process.cleanExit(io);
}
```

- [ ] **Step 9: Wire an audit-only build step**

Modify `build.zig` to add one host generator executable and a `gen-runicode` step that passes `UCD` as the first argument. Do not remove existing generator steps yet.

- [ ] **Step 10: Run build audit**

Run: `zig build gen-runicode`

Expected: pass with no unknown UCD files.

- [ ] **Step 11: Commit**

```bash
git add build.zig src/gen/runicode-gen.zig src/gen/ucd/manifest.zig src/gen/ucd/audit.zig
git commit -m "feat(gen): add UCD manifest audit"
```

### Task 2: Generic UCD Parsing Primitives

**Files:**
- Create: `src/gen/ucd/parse.zig`
- Modify: `src/gen/runicode-gen.zig`

- [ ] **Step 1: Write parser tests**

Create tests for point, range, sequence, comment stripping, and semicolon fields:

```zig
test "parse codepoint range parses point and range" {
    try testing.expectEqual(Range{ .first = 0x41, .last = 0x41 }, try parseCodepointRange("0041"));
    try testing.expectEqual(Range{ .first = 0x41, .last = 0x5A }, try parseCodepointRange("0041..005A"));
}

test "parse scalar sequence parses space-separated codepoints" {
    const seq = try parseScalarSequence(testing.allocator, "0023 FE0F 20E3");
    defer testing.allocator.free(seq);
    try testing.expectEqualSlices(u21, &.{ 0x23, 0xFE0F, 0x20E3 }, seq);
}

test "fields strips comments and trims fields" {
    var parsed = try fields(testing.allocator, "0041..005A ; Lu # [26] letters");
    defer parsed.deinit(testing.allocator);
    try testing.expectEqualStrings("0041..005A", parsed.items[0]);
    try testing.expectEqualStrings("Lu", parsed.items[1]);
}
```

- [ ] **Step 2: Run parser tests and confirm failure**

Run: `zig test src/gen/ucd/parse.zig`

Expected: fail because parser file does not exist.

- [ ] **Step 3: Implement parser primitives**

Create `src/gen/ucd/parse.zig` with:

```zig
pub const Range = struct {
    first: u21,
    last: u21,
};

pub const FieldList = struct {
    items: []const []const u8,

    pub fn deinit(list: FieldList, allocator: std.mem.Allocator) void {
        allocator.free(list.items);
    }
};

pub fn parseCodepoint(text: []const u8) !u21 {
    return std.fmt.parseInt(u21, text, 16);
}

pub fn parseCodepointRange(text: []const u8) !Range {
    if (std.mem.indexOf(u8, text, "..")) |dots| {
        return .{
            .first = try parseCodepoint(text[0..dots]),
            .last = try parseCodepoint(text[dots + 2 ..]),
        };
    }
    const point = try parseCodepoint(text);
    return .{ .first = point, .last = point };
}

pub fn parseScalarSequence(allocator: std.mem.Allocator, text: []const u8) ![]u21 {
    var list: std.ArrayList(u21) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |part| {
        try list.append(allocator, try parseCodepoint(part));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn fields(allocator: std.mem.Allocator, line: []const u8) !FieldList {
    const uncommented = if (std.mem.indexOfScalar(u8, line, '#')) |hash| line[0..hash] else line;
    const trimmed = std.mem.trim(u8, uncommented, " \t\r\n");
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    while (it.next()) |field| {
        try list.append(allocator, std.mem.trim(u8, field, " \t\r\n"));
    }
    return .{ .items = try list.toOwnedSlice(allocator) };
}
```

- [ ] **Step 4: Run parser tests**

Run: `zig test src/gen/ucd/parse.zig`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/gen/ucd/parse.zig
git commit -m "feat(gen): add UCD parser primitives"
```

### Task 3: Alias Loading

**Files:**
- Create: `src/gen/ucd/aliases.zig`
- Modify: `src/gen/runicode-gen.zig`

- [ ] **Step 1: Write alias tests using fixture text**

Add tests that load small in-memory alias fixtures:

```zig
test "value aliases resolve canonical names and aliases" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try aliases.loadPropertyValueLine("gc ; Lu ; Uppercase_Letter");
    try aliases.loadPropertyValueLine("gc ; Nd ; Decimal_Number ; digit");

    try testing.expectEqualStrings("Uppercase_Letter", aliases.canonicalValue("gc", "Lu").?);
    try testing.expectEqualStrings("Decimal_Number", aliases.canonicalValue("gc", "digit").?);
}

test "property aliases resolve short names" {
    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();

    try aliases.loadPropertyLine("gc ; General_Category");
    try aliases.loadPropertyLine("sc ; Script");

    try testing.expectEqualStrings("General_Category", aliases.canonicalProperty("gc").?);
    try testing.expectEqualStrings("Script", aliases.canonicalProperty("sc").?);
}
```

- [ ] **Step 2: Run alias tests and confirm failure**

Run: `zig test src/gen/ucd/aliases.zig`

Expected: fail because alias loader does not exist.

- [ ] **Step 3: Implement alias loader**

Create an `Aliases` type with:

```zig
pub const Aliases = struct {
    allocator: std.mem.Allocator,
    properties: std.StringHashMapUnmanaged([]const u8) = .empty,
    values: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty,

    pub fn init(allocator: std.mem.Allocator) Aliases {
        return .{ .allocator = allocator };
    }

    pub fn deinit(aliases: *Aliases) void {
        var value_it = aliases.values.valueIterator();
        while (value_it.next()) |map| map.deinit(aliases.allocator);
        aliases.values.deinit(aliases.allocator);
        aliases.properties.deinit(aliases.allocator);
    }

    pub fn canonicalProperty(aliases: *Aliases, name: []const u8) ?[]const u8 {
        return aliases.properties.get(name);
    }

    pub fn canonicalValue(aliases: *Aliases, property: []const u8, value: []const u8) ?[]const u8 {
        const map = aliases.values.get(property) orelse return null;
        return map.get(value);
    }
};
```

Implement `loadPropertyLine`, `loadPropertyValueLine`, `loadPropertyAliasesFile`, and `loadPropertyValueAliasesFile` using `parse.fields`.

- [ ] **Step 4: Run alias tests**

Run: `zig test src/gen/ucd/aliases.zig`

Expected: pass.

- [ ] **Step 5: Load aliases in generator main**

Modify `src/gen/runicode-gen.zig` so after audit it opens `PropertyAliases.txt` and `PropertyValueAliases.txt` through the UCD dir and loads them into `Aliases`.

- [ ] **Step 6: Run build audit**

Run: `zig build gen-runicode`

Expected: pass and still emit no generated data roots.

- [ ] **Step 7: Commit**

```bash
git add src/gen/runicode-gen.zig src/gen/ucd/aliases.zig
git commit -m "feat(gen): load UCD alias metadata"
```

### Task 4: Property Database And Generic Readers

**Files:**
- Create: `src/gen/ucd/db.zig`
- Modify: `src/gen/runicode-gen.zig`

- [ ] **Step 1: Write database tests**

Test that a range can be appended to a namespace and read back as both codepoints and UTF-8:

```zig
test "property group accumulates range as codepoints and utf8" {
    var db = Db.init(testing.allocator);
    defer db.deinit();

    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x43 });

    const prop = db.property("GeneralCategory").?;
    const value = prop.value("Lu").?;
    try testing.expectEqualSlices(u21, &.{ 0x41, 0x42, 0x43 }, value.codepoints.items);
    try testing.expectEqualStrings("ABC", value.utf8.items);
}
```

- [ ] **Step 2: Run database tests and confirm failure**

Run: `zig test src/gen/ucd/db.zig`

Expected: fail because `db.zig` does not exist.

- [ ] **Step 3: Implement `Db`, `PropertyGroup`, and `PropertyValue`**

Create `src/gen/ucd/db.zig` with owned string-keyed maps, a `CodepointList`, a UTF-8 byte list, and `addRange` using `std.unicode.utf8Encode`.

- [ ] **Step 4: Run database tests**

Run: `zig test src/gen/ucd/db.zig`

Expected: pass.

- [ ] **Step 5: Implement generic property file reader**

Add to `src/gen/runicode-gen.zig` or a focused helper in `db.zig`:

```zig
fn readCodepointPropertyFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *Aliases,
    entry: manifest.UcdFile,
) !void
```

It must open `entry.path`, read each non-comment line, parse two or three semicolon fields, resolve the property name from `entry.property` or the second field for compound files, resolve value aliases when present, and call `db.addRange`.

- [ ] **Step 6: Read all generic property manifest entries**

In `main`, iterate over `manifest.known_files` and process `.codepoint_property` entries with the generic reader. Ignore all other kinds for now.

- [ ] **Step 7: Add a generator summary output**

Print one line to stderr or stdout:

```text
runicode-gen: loaded <N> property groups
```

- [ ] **Step 8: Run generator**

Run: `zig build gen-runicode`

Expected: pass and print a nonzero property group count.

- [ ] **Step 9: Commit**

```bash
git add src/gen/runicode-gen.zig src/gen/ucd/db.zig
git commit -m "feat(gen): read generic UCD properties"
```

### Task 5: Generated Roots For Properties

**Files:**
- Create: `src/gen/ucd/emit.zig`
- Modify: `src/gen/runicode-gen.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write emitter tests**

Use a tiny in-memory `Db` and a temporary directory. Verify `sets.zig`, `codepoints.zig`, `strs.zig`, and `enums.zig` are produced and contain a known declaration:

```zig
test "emitter writes property roots" {
    var db = Db.init(testing.allocator);
    defer db.deinit();
    try db.addRange("GeneralCategory", "Lu", .{ .first = 0x41, .last = 0x41 });

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try emitRoots(testing.allocator, tmp.dir, &db);

    const strs = try tmp.dir.readFileAlloc(testing.allocator, "strs.zig", 1 << 20);
    defer testing.allocator.free(strs);
    try testing.expect(std.mem.indexOf(u8, strs, "pub const GeneralCategory") != null);
    try testing.expect(std.mem.indexOf(u8, strs, "pub const Lu") != null);
}
```

- [ ] **Step 2: Run emitter tests and confirm failure**

Run: `zig test src/gen/ucd/emit.zig`

Expected: fail because emitter does not exist.

- [ ] **Step 3: Implement root emitters**

Create `emitRoots` and writer helpers:

- `writeStrsRoot`: emits nested structs with `pub const <Value> = "<utf8>";`.
- `writeCodepointsRoot`: emits nested structs with `pub const <Value>: [N]u21 = .{ ... };`.
- `writeSetsRoot`: emits nested structs with serialized `RuneSet` values.
- `writeEnumsRoot`: emits one enum per property group.
- `writeMapsRoot`: emits a `NamedMap` forwarding namespace for every property group.

Use existing `runeset.RuneSet.createFromConstString` and `serialize` behavior from the old generators.

- [ ] **Step 4: Run emitter tests**

Run: `zig test src/gen/ucd/emit.zig`

Expected: pass.

- [ ] **Step 5: Add output file args to generator main**

Make `runicode-gen` require these arguments:

```text
runicode-gen UCD sets.zig codepoints.zig strs.zig enums.zig maps.zig
```

The executable should emit all five files after loading generic properties.

- [ ] **Step 6: Wire generated roots in build**

In `build.zig`, use:

```zig
const run_gen = b.addRunArtifact(runicode_gen_exe);
run_gen.addDirectoryArg(b.path("UCD"));
const generated_sets = run_gen.addOutputFileArg("sets.zig");
const generated_codepoints = run_gen.addOutputFileArg("codepoints.zig");
const generated_strs = run_gen.addOutputFileArg("strs.zig");
const generated_enums = run_gen.addOutputFileArg("enums.zig");
const generated_maps = run_gen.addOutputFileArg("maps.zig");
```

Create modules from those generated files and import them into `runicode_mod` as `generated_sets`, `generated_codepoints`, `generated_strs`, `generated_enums`, and `generated_maps`.

- [ ] **Step 7: Run build generation**

Run: `zig build gen-runicode`

Expected: pass and produce generated output files in the build cache.

- [ ] **Step 8: Commit**

```bash
git add build.zig src/gen/runicode-gen.zig src/gen/ucd/emit.zig
git commit -m "feat(gen): emit generated property roots"
```

### Task 6: Facade Flip While Preserving Current Public Names

**Files:**
- Modify: `src/runicode.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write facade tests against generated imports**

Update tests in `src/runicode.zig` so they check generated imports:

```zig
test "public root forwards generated namespaces" {
    try testing.expect(sets.GeneralCategory.Lu.equalTo(@import("generated_sets").GeneralCategory.Lu));
    try testing.expectEqualSlices(u21, &codepoints.GeneralCategory.Lu, &@import("generated_codepoints").GeneralCategory.Lu);
    try testing.expectEqualStrings(strs.GeneralCategory.Lu, @import("generated_strs").GeneralCategory.Lu);
    try testing.expectEqual(enums.GeneralCategoryKind.Lu, .Lu);
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run: `zig build test`

Expected: fail because `src/runicode.zig` still imports checked-in generated files.

- [ ] **Step 3: Update facade imports**

Change top-level declarations to:

```zig
pub const sets = @import("generated_sets");
pub const codepoints = @import("generated_codepoints");
pub const strs = @import("generated_strs");
pub const enums = @import("generated_enums");
pub const maps = @import("generated_maps");
pub const NamedMap = @import("ucd-tools").NamedMap;
```

Keep compatibility map declarations if existing call sites still expect `sets.map`, `codepoints.map`, or `strs.map`. If the generated roots include `.map`, forward through those generated structures instead of duplicating map definitions in the facade.

- [ ] **Step 4: Run tests**

Run: `zig build test`

Expected: pass for all currently generated generic property coverage or fail only on missing special handlers identified in later tasks.

- [ ] **Step 5: Commit**

```bash
git add build.zig src/runicode.zig
git commit -m "feat: forward runicode facade to generated roots"
```

### Task 7: Special Set-Shaped Handlers

**Files:**
- Create: `src/gen/ucd/special.zig`
- Modify: `src/gen/runicode-gen.zig`
- Modify: `src/gen/ucd/db.zig`

- [ ] **Step 1: Write tests for one-field set and script extensions**

Add:

```zig
test "one-field set adds points to configured property" {
    var db = Db.init(testing.allocator);
    defer db.deinit();
    try readOneFieldSetLine(&db, "CompositionExclusion", "Composition_Exclusion", "0958");
    try testing.expect(db.property("CompositionExclusion").?.value("Composition_Exclusion") != null);
}

test "script extensions appends a range to every listed script" {
    var db = Db.init(testing.allocator);
    defer db.deinit();
    var short = std.StringHashMap([]const u8).init(testing.allocator);
    defer short.deinit();
    try short.put("Latn", "Latin");
    try short.put("Grek", "Greek");

    try readScriptExtensionsLine(&db, &short, "00B7 ; Latn Grek");

    try testing.expect(db.property("ScriptsExtended").?.value("Latin") != null);
    try testing.expect(db.property("ScriptsExtended").?.value("Greek") != null);
}
```

- [ ] **Step 2: Run special tests and confirm failure**

Run: `zig test src/gen/ucd/special.zig`

Expected: fail because handlers do not exist.

- [ ] **Step 3: Implement one-field set and script extension handlers**

Create `src/gen/ucd/special.zig` with public functions:

```zig
pub fn readOneFieldSetFile(...) !void
pub fn readScriptExtensionsFile(...) !void
pub fn readScriptExtensionsLine(...) !void
```

`readScriptExtensionsFile` must build a short-to-long script map from property value aliases for property `sc`.

- [ ] **Step 4: Integrate handlers into main manifest loop**

Handle `.one_field_set` and `.script_extensions` in `runicode-gen`.

- [ ] **Step 5: Run build tests**

Run: `zig build test`

Expected: pass with `Composition_Exclusion` and `ScriptsExtended` generated.

- [ ] **Step 6: Commit**

```bash
git add src/gen/runicode-gen.zig src/gen/ucd/special.zig src/gen/ucd/db.zig
git commit -m "feat(gen): handle special set-shaped UCD files"
```

### Task 8: Special Map And Record Surfaces

**Files:**
- Modify: `src/gen/ucd/special.zig`
- Modify: `src/gen/ucd/db.zig`
- Modify: `src/gen/ucd/emit.zig`
- Modify: `src/gen/runicode-gen.zig`

- [ ] **Step 1: Add special record storage tests**

Add tests to `db.zig` for scalar maps, sequence maps, and record lists:

```zig
test "db stores scalar map record" {
    var db = Db.init(testing.allocator);
    defer db.deinit();
    try db.addScalarMap("BidiMirroring", 0x28, 0x29);
    try testing.expectEqual(@as(u21, 0x29), db.scalarMap("BidiMirroring").?.get(0x28).?);
}

test "db stores named sequence record" {
    var db = Db.init(testing.allocator);
    defer db.deinit();
    try db.addSequence("NamedSequences", "KEYCAP NUMBER SIGN", &.{ 0x23, 0xFE0F, 0x20E3 });
    try testing.expectEqual(@as(usize, 1), db.sequenceMap("NamedSequences").?.count());
}
```

- [ ] **Step 2: Implement storage for special data**

Add owned collections for:

- scalar maps: `namespace -> []const ScalarPair`
- sequences: `namespace -> []const NamedSequence`
- records: `namespace -> []const Record`
- case folding: `[]const CaseFold`
- special casing: `[]const SpecialCase`

- [ ] **Step 3: Implement map and record readers**

Implement handlers for:

- `BidiBrackets.txt`
- `BidiMirroring.txt`
- `CaseFolding.txt`
- `SpecialCasing.txt`
- `UnicodeData.txt`
- `DerivedNormalizationProps.txt`
- `EquivalentUnifiedIdeograph.txt`
- `Jamo.txt`
- `NameAliases.txt`
- `NamedSequences.txt`
- `NormalizationCorrections.txt`
- `StandardizedVariants.txt`
- `emoji/emoji-variation-sequences.txt`
- `extracted/DerivedName.txt`
- `extracted/DerivedNumericValues.txt`

For files whose polished public API is larger than this refactor needs, emit typed raw records with parsed fields rather than skipping the file.

- [ ] **Step 4: Emit special roots**

Extend `emit.zig` to write special namespaces into `maps.zig` or additional generated roots. Each special file must produce at least one typed declaration whose name matches the manifest namespace.

- [ ] **Step 5: Run full generator**

Run: `zig build gen-runicode`

Expected: pass with no "known special not handled" diagnostics.

- [ ] **Step 6: Run tests**

Run: `zig build test`

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add src/gen/runicode-gen.zig src/gen/ucd/db.zig src/gen/ucd/emit.zig src/gen/ucd/special.zig
git commit -m "feat(gen): emit special UCD map records"
```

### Task 9: Remove Checked-In Generated Data

**Files:**
- Delete: generated leaves under `src/sets`, `src/codepoints`, `src/strs`, `src/enums`
- Keep: checked-in source files needed by facade and generator
- Modify: `build.zig.zon`

- [ ] **Step 1: Confirm generated roots cover current tests**

Run: `zig build test`

Expected: pass before deleting checked-in data.

- [ ] **Step 2: Remove obsolete generated source trees**

Delete checked-in generated data files that are no longer imported by `src/runicode.zig`. Keep `src/runicode.zig`, `src/gen`, and any hand-written source.

- [ ] **Step 3: Update package paths**

In `build.zig.zon`, keep:

```zig
.paths = .{
    "build.zig",
    "build.zig.zon",
    "src",
    "UCD",
    "LICENSE",
    "README.md",
},
```

- [ ] **Step 4: Run tests after deletion**

Run: `zig build test`

Expected: pass, proving no checked-in generated leaves are required.

- [ ] **Step 5: Commit**

```bash
git add build.zig.zon src
git commit -m "refactor: remove checked-in generated Unicode data"
```

### Task 10: Final Verification And Cleanup

**Files:**
- Modify only files with failing formatting or stale imports.

- [ ] **Step 1: Format changed Zig files**

Run: `zig fmt build.zig src/runicode.zig src/gen/runicode-gen.zig src/gen/ucd/manifest.zig src/gen/ucd/audit.zig src/gen/ucd/parse.zig src/gen/ucd/aliases.zig src/gen/ucd/db.zig src/gen/ucd/emit.zig src/gen/ucd/special.zig`

Expected: command exits 0.

- [ ] **Step 2: Run full tests**

Run: `zig build test`

Expected: pass.

- [ ] **Step 3: Verify unknown-file failure manually**

Create a temporary copy of `UCD`, add `Surprise.txt`, run the generator against that temp directory, and confirm it fails with `unknown UCD file: Surprise.txt`. Use a temp directory outside the repo so the real UCD tree stays unchanged.

- [ ] **Step 4: Inspect git status**

Run: `git status --short`

Expected: only intentional source and deletion changes are present.

- [ ] **Step 5: Commit verification cleanup**

If formatting or cleanup changed files:

```bash
git add build.zig build.zig.zon src
git commit -m "chore: verify generated runicode build"
```

If no files changed, do not create an empty commit.

## Self-Review

- Spec coverage: The plan covers the manifest audit, bundled UCD generation, preserved facade names, generic property files, special handlers, known skips, build integration, checked-in generated data removal, and verification.
- Placeholder scan: The plan names each file, command, and expected result.
- Type consistency: The plan consistently uses `UcdFile`, `FileKind`, `Db`, `Aliases`, `auditDir`, `emitRoots`, `readCodepointPropertyFile`, and generated import names.
