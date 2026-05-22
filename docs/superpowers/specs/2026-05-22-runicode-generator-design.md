# Runicode Import-Time Generator Design

## Goal

Runicode should stop checking in generated Unicode data modules. The package will
ship the UCD data and a single host-side generator. Importing the `runicode`
module through Zig's build graph will generate all derived Zig modules into the
build cache and then expose the same top-level names through a small checked-in
facade.

The generator must also know about every file in the bundled UCD tree. If the
tree contains an unknown file, ordinary `zig build` must fail. Unicode upgrades
are expected to be a maintainer-only workflow, so failing fast is the desired
signal that a new file needs a decision.

## Public Shape

Keep `src/runicode.zig` checked in as the stable public facade. It should expose
the same top-level concepts it exposes today:

- `sets`
- `codepoints`
- `strs`
- `enums`
- `NamedMap`

Each top-level declaration should be a forwarding import into generated modules,
the way `NamedMap` is currently forwarded from `ucd-tools`.

Generated property namespaces should preserve the current naming style where it
exists. New property families should follow the same pattern: a generated enum,
codepoint arrays, UTF-8 strings, RuneSet values, and a loose-matching map when
aliases are available.

## Build Shape

`build.zig` should follow the Woodward pattern:

1. Build one host generator executable.
2. Pass the bundled `UCD/` directory and generated output paths as arguments.
3. Use `addOutputFileArg` for generated root modules.
4. Create Zig modules from those generated output files.
5. Add those generated modules as imports to the checked-in `runicode` facade.

The UCD directory must remain in `build.zig.zon` package paths so downstream
consumers generate from the same data shipped with the package.

The old per-property generator executables can disappear once the new generator
emits equivalent or broader coverage.

## Generator Architecture

The generator should be manifest-driven. A checked-in table is the source of
truth for UCD file handling:

```zig
const known_files = [_]UcdFile{
    .{
        .path = "Blocks.txt",
        .kind = .codepoint_property,
        .property = "blk",
        .namespace = "Blocks",
    },
    .{
        .path = "ScriptExtensions.txt",
        .kind = .script_extensions,
        .property = "scx",
        .namespace = "ScriptsExtended",
    },
    .{
        .path = "CaseFolding.txt",
        .kind = .case_folding,
        .namespace = "CaseFolding",
    },
    .{
        .path = "BidiTest.txt",
        .kind = .known_skip,
        .reason = "conformance test",
    },
};
```

At startup the generator walks `UCD/`, ignores filesystem metadata such as
`.DS_Store`, and verifies every real UCD file appears in `known_files`. Unknown
files are errors. Known skipped files do nothing except document why they are
outside Runicode's current structures.

The generator should build an in-memory `UcdDb` from all generated entries, then
emit all modules in one pass. Generic property files should share parser and
emitter code instead of one executable per property family.

## Generic Property Handling

Many UCD files have the shape:

```text
<codepoint-or-range> ; <property-value>
```

These should use a common handler that:

1. Parses codepoints and ranges.
2. Resolves property value aliases through `PropertyValueAliases.txt`.
3. Accumulates values by property family and canonical value name.
4. Emits UTF-8 strings, sorted `u21` arrays, serialized RuneSets, enums, and
   loose maps.

Where both a primary and extracted file exist, prefer the file which is the
direct consumable property view. For example, use extracted files for
`DerivedGeneralCategory`, `DerivedBidiClass`, and similar derived properties
when exposing those properties.

## Files To Generate As Properties

Current coverage to preserve:

- `Blocks.txt`
- `DerivedCoreProperties.txt`
- `PropList.txt`
- `Scripts.txt`
- `ScriptExtensions.txt`
- `emoji/emoji-data.txt`
- `auxiliary/GraphemeBreakProperty.txt`
- `auxiliary/SentenceBreakProperty.txt`
- `auxiliary/WordBreakProperty.txt`
- `extracted/DerivedGeneralCategory.txt`

Additional UCD property files to expose:

- `DerivedAge.txt`
- `EastAsianWidth.txt`
- `HangulSyllableType.txt`
- `IndicPositionalCategory.txt`
- `IndicSyllabicCategory.txt`
- `LineBreak.txt`
- `VerticalOrientation.txt`
- `extracted/DerivedBidiClass.txt`
- `extracted/DerivedBinaryProperties.txt`
- `extracted/DerivedCombiningClass.txt`
- `extracted/DerivedDecompositionType.txt`
- `extracted/DerivedEastAsianWidth.txt`
- `extracted/DerivedJoiningGroup.txt`
- `extracted/DerivedJoiningType.txt`
- `extracted/DerivedLineBreak.txt`
- `extracted/DerivedNumericType.txt`

`CompositionExclusions.txt` is a set-shaped file with one codepoint per data
line. It should generate the `Composition_Exclusion` set and can share most of
the property emission path with a small parser adapter.

## Special Handlers

Some UCD files are valuable but not simple property sets.

- `PropertyAliases.txt`: property alias metadata. Use it for canonical property
  names and future loose property-name support.
- `PropertyValueAliases.txt`: value aliases. Use it for enum names, forwarded
  alias constants, and loose value maps.
- `ScriptExtensions.txt`: expand short script aliases and append each range to
  every listed script. This remains the main special case among set-shaped
  files.
- `BidiBrackets.txt`: emit bracket-pair maps and the `Bidi_Paired_Bracket_Type`
  property sets.
- `BidiMirroring.txt`: emit a codepoint-to-codepoint map for
  `Bidi_Mirroring_Glyph`.
- `CaseFolding.txt`: emit fold mappings and a helper surface for the existing
  case-insensitive RuneSet idea.
- `SpecialCasing.txt`: emit casing maps, splitting unconditional mappings from
  conditional or locale-sensitive entries.
- `UnicodeData.txt`: treat as a record source for core scalar metadata and
  simple casing mappings where needed.
- `extracted/DerivedName.txt`: emit codepoint-to-derived-name data, including
  generated name patterns for ranges.
- `extracted/DerivedNumericValues.txt`: emit numeric value records for codepoints
  and ranges.
- `DerivedNormalizationProps.txt`: split its mixed contents into quick-check
  property sets and NFKC casefold string mappings.
- `EquivalentUnifiedIdeograph.txt`: emit codepoint-to-codepoint mappings.
- `Jamo.txt`: emit Jamo short-name mappings.
- `NameAliases.txt`: emit codepoint-to-name-alias lists.
- `NamedSequences.txt`: emit named sequence data.
- `NormalizationCorrections.txt`: emit normalization correction records.
- `StandardizedVariants.txt`: emit standardized variation sequence records.
- `emoji/emoji-variation-sequences.txt`: emit emoji variation sequence records.

The first implementation can sketch these special surfaces before every map API
is polished, but each file must have an explicit manifest entry and either
generate useful output or document why it is deferred.

## Known Skips

Skip files which do not match Runicode's set/string/codepoint/map structures or
are conformance inputs rather than property data.

Conformance tests:

- `BidiCharacterTest.txt`
- `BidiTest.txt`
- `NormalizationTest.txt`
- `auxiliary/GraphemeBreakTest.txt`
- `auxiliary/LineBreakTest.txt`
- `auxiliary/SentenceBreakTest.txt`
- `auxiliary/WordBreakTest.txt`
- `auxiliary/GraphemeBreakTest.html`
- `auxiliary/LineBreakTest.html`
- `auxiliary/SentenceBreakTest.html`
- `auxiliary/WordBreakTest.html`

Docs and rendered reference material:

- `ReadMe.txt`
- `emoji/ReadMe.txt`
- `NamesList.txt`
- `NamesList.html`
- `USourceGlyphs.pdf`
- `USourceRSChart.pdf`

Catalog/source data outside the current public structures:

- `ArabicShaping.txt`, if `DerivedJoiningType.txt` and
  `DerivedJoiningGroup.txt` are used as the exposed property views
- `CJKRadicals.txt`
- `DoNotEmit.txt`
- `EmojiSources.txt`
- `Index.txt`
- `NamedSequencesProv.txt`, empty in the bundled UCD version
- `NushuSources.txt`
- `TangutSources.txt`
- `USourceData.txt`
- `Unikemet.txt`

These skip entries are still important. They keep the audit complete and make
future UCD upgrades intentional.

## Emission Strategy

The generator should emit a small number of generated root files instead of
thousands of checked-in leaf files. It may still emit per-namespace or per-value
files into the build cache if that improves compiler behavior, but the generated
roots should be what `src/runicode.zig` imports.

Suggested generated roots:

- `generated/sets.zig`
- `generated/codepoints.zig`
- `generated/strs.zig`
- `generated/enums.zig`
- `generated/maps.zig`
- optional special roots such as `generated/case_folding.zig`

The exact file split can change during implementation if Zig parse time or
module ergonomics point to a better layout.

## Error Handling

Build-time failures should be direct and actionable:

- Unknown UCD file: print its relative path and fail.
- Known generated file with an unexpected format: print the manifest entry path
  and line number.
- Alias resolution miss: print the property, value, source file, and line.
- Duplicate canonical output name: print both sources.

The generator should not silently skip malformed data.

## Tests And Verification

Unit tests should cover:

- Manifest audit rejects unknown files.
- Generic property parser handles points, ranges, and aliases.
- `ScriptExtensions.txt` appends one range to multiple scripts.
- Loose matching maps continue to resolve aliases.
- Generated roots expose current public names.

Build verification should include:

- `zig fmt` on changed Zig files.
- `zig build test`, proving generated modules are created from bundled UCD data.
- A targeted test or fixture that adds an unknown temporary UCD file and confirms
  the generator fails.

## Non-Goals

This change does not need to invent APIs for every possible UCD semantic use.
Files that cleanly fit Runicode's current structures should be generated.
Special files should be acknowledged and sketched or implemented with focused
handlers. Source files that are primarily documentation, conformance corpora, or
domain-specific catalog data can remain known skips.
