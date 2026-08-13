# Runicode


A project for working with the [UCD] data in Zig code.

Primarily, this code-generates [RuneSets] for the bulk of the set-like
categories in the Unicode database.  These can also be made available as
arrays of codepoints, or as strings, in case that might come in handy.

These are organized into static namespaces.  They may also be retrieved
at runtime in a map-like fashion, following the Unicode loose-matching
rules: do be aware that making use of them in this fashion will cause
all sets to be included in the binary.

This goes so far as to allow retrieval of single codepoints by name,
also following loose matching.  This is done efficiently with a port of
@burntsushi 's [fst] library.

The repo exists to be a dependency of something else, and it's unlikely
that you personally need `runicode` rather than, say, [zg][].  As such
I'm not putting my back out providing detailed documentation of its use.
The sort of hacker who does have a use for `runicode` is going to skip
right past that and read the build script, anyway.

_Most_ of UCD is packed into sets here, but not _all_ of it.  If you
have a use case for something I didn't cover, let me know.

[RuneSets]: http://github.com/mnemnion/runeset
[UCD]: https://www.unicode.org/reports/tr44/tr44-33.html
[fst]: https://github.com/BurntSushi/fst
[zg]: https://codeberg.org/atman/zg

