# Runicode

The runicode project aims to make Unicode data accessible to Zig programs.  This is done to a substantial degree with [RunSets](http://github.com/mnemnion/runeset), which provide a succinct and decently performant set structure for UTF-8 encoded data.

The library does not focus on algorithms for string manipulation, and should be seen as complementary to [zg](https://codeberg.org/atman/zg), which has a battle-tested library of such algorithms, and a different data structure with its own strengths and weaknesses.

Runicode is not a complete one-to-one translation of the [UCD](https://www.unicode.org/reports/tr44/tr44-33.html), and may never become so. The primary focus has been on collections of codepoints fairly represented as sets, while the UCD has numerous mappings, metadata, and other data which cannot usefully be composed into set form.

## Runicode and Zg

`zg`, in addition to providing algorithms like case folding and grapheme breaks, also has modules which map codepoints to various properties on a many-to-many basis.  The multi-stage lookup tables used are optimal for this purpose.  In some cases `runicode` provides equivalent functionality, but as a raw material: RuneMaps containing every assigned codepoint (or indeed every codepoint) in Unicode are not able to perform such lookups with comparable efficiency.

What you can do with `runicode`, which `zg` does not provide, is set operations on these categories and properties.  With `runicode`, one can create, for example, a set matching every codepoint in the extended Greek script set, matching those (and only those) to their General Category.  Or a set consisting of all lowercase codepoints in the extended Greek script.

Matching these properties using `zg` is possible, perhaps with several lookups, but to do so one must write a function which does it.  Runesets are data: one may use standard set operations to construct the set or map of interest, and then use it generically to recognize codepoints in that set, and map them to some value in the case of RuneMaps.  While RuneSet performance varies by the size of the set of interest, it is quite efficient even for sets of thousands of codepoints, enough so to be suitable as a component in a pattern matching system, such as a regular expression engine or PEG parsing machine. As a point of interest, the Greek Extended runeset is 30 64 bit words in size.

