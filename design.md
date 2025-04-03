# Design

The task itself is relatively straightforward.  We parse the UCD database and codegen Zig files which contain strings matching all the categories.

Then, a second build stage reads all the strings, allocates Runesets, and does a second round of codegen emitting the Runesets as static constants.

## Considerations

Most of these strings will be reasonably small, some will be unreasonably large. I want to take a completionist approach here, which doesn't try and empirically exclude sets which are large enough that some better technique is justified.

Zig is lazily compiled, so there's no concern with bloating (most) programs which will consume Runicode.  But the compiler would still have to parse some very large files, if I were to generate very large files.  So the plan is for each string to be one file, with categories just `@import`-forwarding namespaces.

Which raises an interesting question about generation: every Runeset would depend on only one string, so given the right dependency mappings I could technically only update Runesets for which the underlying string has changed.

As tempting as that sounds, as a purely technical Sudoko-solving kind of problem, there's just no point.  Once the library is developed, generation has to happen... once per Unicode release.  I'm also the only person who should ever need to do it.

So it should be alright to just say that anytime anything in the strings module changes, everything in the runesets module changes as well.

## Specialty Code

The main event is just sets.  But a subset of Unicode data is actually _mappings_.  I can, and the script will, generate a set for Bidi Mirror, but that's basically useless compared to the intended purpose, which is to mirror characters in a bidirectional context (and other useful things like general-purpose brace-match generators for text).

There's also at least one case where I want to map from a character to a Runeset: case folding.  Case-insensitive search wants to use insensitive tokens, not convert the entire haystack to lowercase, even dynamically.  So the problem statement here is "given a case-foldable letter, get a Runeset which matches all variations", and we're going to have those (an exception to the one-Runeset-per-file rule!).

This suggests another expansion to Runeset: a RuneMap generic type.  I already have the function which can return the order of a rune in a set, this is a relatively simple matter of combining two slices and providing some methods to go with.
