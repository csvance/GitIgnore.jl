using Test
using GitIgnore
using GitIgnore: ignore_glob_to_regex, parse_ignore_line

# A matcher whose only rules are the lines given here, so pattern semantics can
# be checked without touching the filesystem. The root does not exist, which is
# the point: an explicit matcher must never look.
inline(lines::AbstractString...; prefix::AbstractString = "") =
    IgnoreMatcher("/nonexistent", [prefix => join(lines, "\n")])

@testset "gitignore line parsing" begin
    @test parse_ignore_line("") === nothing
    @test parse_ignore_line("   ") === nothing
    @test parse_ignore_line("# a comment") === nothing
    @test parse_ignore_line("!") === nothing
    @test parse_ignore_line("/") === nothing

    negated = parse_ignore_line("!keep.log")
    @test negated.negated
    @test !negated.dir_only

    dir_only = parse_ignore_line("build/")
    @test dir_only.dir_only
    @test !dir_only.negated

    # An escaped leading `#` is a filename, not a comment.
    literal_hash = parse_ignore_line("\\#notes")
    @test literal_hash !== nothing
    @test occursin(literal_hash.regex, "#notes")

    # Trailing whitespace is dropped unless a backslash quotes it.
    @test occursin(parse_ignore_line("trailing.txt   ").regex, "trailing.txt")
    @test occursin(parse_ignore_line("space\\ ").regex, "space ")
end

@testset "gitignore pattern semantics" begin
    # No separator: matches a basename at any depth.
    anywhere = inline("*.log")
    @test isignored(anywhere, "a.log", false)
    @test isignored(anywhere, "deep/nested/a.log", false)
    @test !isignored(anywhere, "a.logs", false)

    # A separator anchors the pattern to the declaring directory.
    anchored = inline("src/*.jl")
    @test isignored(anchored, "src/main.jl", false)
    @test !isignored(anchored, "lib/src/main.jl", false)

    # A leading slash anchors without making the pattern recursive.
    rooted = inline("/top.jl")
    @test isignored(rooted, "top.jl", false)
    @test !isignored(rooted, "src/top.jl", false)

    # `*` stops at a separator, `**` crosses it.
    single = inline("a/*/c")
    @test isignored(single, "a/b/c", false)
    @test !isignored(single, "a/b/x/c", false)
    double = inline("a/**/c")
    @test isignored(double, "a/b/c", false)
    @test isignored(double, "a/b/x/c", false)
    # `**/` also matches zero segments.
    @test isignored(double, "a/c", false)

    # A trailing `/**` is everything inside, but not the directory itself.
    inside = inline("logs/**")
    @test isignored(inside, "logs/a.txt", false)
    @test isignored(inside, "logs/deep/a.txt", false)
    @test !isignored(inside, "logs", true)

    # A trailing slash restricts the pattern to directories.
    dirs_only = inline("build/")
    @test isignored(dirs_only, "build", true)
    @test !isignored(dirs_only, "build", false)

    # `?` is one non-separator character; a bracket expression is a class.
    @test isignored(inline("a?c.jl"), "abc.jl", false)
    @test !isignored(inline("a?c.jl"), "a/c.jl", false)
    @test isignored(inline("[abc].txt"), "b.txt", false)
    @test !isignored(inline("[abc].txt"), "d.txt", false)
    @test isignored(inline("[!abc].txt"), "d.txt", false)
    @test !isignored(inline("[!abc].txt"), "b.txt", false)

    # A `.` in a pattern is a literal dot, not a regex wildcard.
    @test !isignored(inline("a.txt"), "axtxt", false)

    # Within one file the last matching line wins, both ways round.
    @test !isignored(inline("*.log", "!keep.log"), "keep.log", false)
    @test isignored(inline("!keep.log", "*.log"), "keep.log", false)

    # An unterminated `[` is inert in git (`wildmatch` returns WM_ABORT_ALL), so
    # the pattern must match nothing rather than becoming a literal bracket.
    @test parse_ignore_line("a[b.txt") === nothing
    @test parse_ignore_line("[abc") === nothing
end

@testset "an inert line costs that line only" begin
    # A `.gitignore` is untrusted input from whatever repository the caller is
    # standing in, and a line git makes inert must cost that line only rather
    # than throwing out of the matcher for the whole tree.
    for bad in ("a[b.txt", "[abc", "[]", "[[=a=]].txt", "[[.a.]].txt")
        @test parse_ignore_line(bad) === nothing
    end
    # A trailing lone backslash is inert in git too.
    @test parse_ignore_line("foo\\") === nothing

    # The bad line matches nothing and the good line after it still applies.
    survivor = inline("[c-a].txt", "*.log")
    @test !isignored(survivor, "a.txt", false)
    @test isignored(survivor, "b.log", false)
end

@testset "bracket expression corner cases" begin
    # A `]` in the first position is a member, not the terminator.
    @test isignored(inline("[]abc].txt"), "].txt", false)
    @test isignored(inline("[!]abc].txt"), "d.txt", false)
    @test !isignored(inline("[!]abc].txt"), "].txt", false)
    # A trailing `-` is a literal, not a broken range.
    @test isignored(inline("[a-].txt"), "-.txt", false)
    @test isignored(inline("[a-].txt"), "a.txt", false)
    # An escaped `]` inside the class.
    @test isignored(inline("[\\]].txt"), "].txt", false)
    # A real range still works.
    @test isignored(inline("[a-c].txt"), "b.txt", false)
    @test !isignored(inline("[a-c].txt"), "d.txt", false)

    # git reads each member literally as it reaches it and applies a range only
    # when it reaches the `-`, so a reversed range still matches its own start
    # character and nothing else. A regex engine rejects `[c-a]` outright, and
    # treating the line as inert instead would leave `c.txt` visible.
    reversed = inline("[c-a].txt")
    @test isignored(reversed, "c.txt", false)
    @test !isignored(reversed, "a.txt", false)
    @test !isignored(reversed, "b.txt", false)
    @test isignored(inline("[9-0].txt"), "9.txt", false)
    @test !isignored(inline("[9-0].txt"), "0.txt", false)

    # A `-` just after a range is a literal, not the start of another.
    dashed = inline("[a-c-e].txt")
    @test all(
        name -> isignored(dashed, name, false),
        ("a.txt", "b.txt", "c.txt", "e.txt", "-.txt")
    )
    @test !isignored(dashed, "d.txt", false)

    # An escape inside a class quotes a literal and nothing else, so `\\d` is the
    # letter d rather than the digit class, and `[a-\\d]` is the range a to d.
    @test isignored(inline("[\\d].txt"), "d.txt", false)
    @test !isignored(inline("[\\d].txt"), "1.txt", false)
    @test isignored(inline("[a-\\d].txt"), "c.txt", false)
    @test !isignored(inline("[a-\\d].txt"), "e.txt", false)
    @test isignored(inline("[\\w-z].txt"), "x.txt", false)
    @test !isignored(inline("[\\w-z].txt"), "a.txt", false)

    # No class matches a separator, whatever it holds: git matches one path
    # component at a time, where a regex class would happily take the `/`.
    @test !isignored(inline("a[!b]c"), "a/c", false)
    @test isignored(inline("a[!b]c"), "axc", false)
    @test !isignored(inline("a[.-0]c"), "a/c", false)
    @test isignored(inline("a[.-0]c"), "a.c", false)
    @test !isignored(inline("a[/]c"), "a/c", false)
end

@testset "POSIX character classes" begin
    # `[[:digit:]]` is legal in a gitignore pattern and is also PCRE syntax, so
    # it passes through. Escaping the `[` would turn it into a class of ":digit"
    # characters followed by a literal `]`, which hides the wrong files.
    digits = inline("[[:digit:]].txt")
    @test isignored(digits, "1.txt", false)
    @test !isignored(digits, "a.txt", false)
    @test !isignored(digits, "[.txt", false)

    alpha = inline("[[:alpha:]][[:digit:]].jl")
    @test isignored(alpha, "a1.jl", false)
    @test !isignored(alpha, "11.jl", false)

    # Collating elements and equivalence classes are git syntax that PCRE does
    # not implement, so the pattern is inert rather than mistranslated.
    @test parse_ignore_line("[[=a=]].txt") === nothing
    @test parse_ignore_line("[[.a.]].txt") === nothing
end

@testset "git's whitespace, CR and BOM rules" begin
    # Trailing spaces go unless escaped; trailing TABS stay, because git's
    # trim_trailing_spaces switches on ' ' alone.
    @test occursin(parse_ignore_line("trailing.txt   ").regex, "trailing.txt")
    @test occursin(parse_ignore_line("space\\ ").regex, "space ")
    tabbed = parse_ignore_line("tabbed.txt\t")
    @test occursin(tabbed.regex, "tabbed.txt\t")
    @test !occursin(tabbed.regex, "tabbed.txt")

    # Exactly one trailing CR is the CRLF the line split left behind; a second
    # one is part of the pattern, so it matches nothing on a normal filename.
    @test occursin(parse_ignore_line("a.txt\r").regex, "a.txt")
    @test !occursin(parse_ignore_line("a.txt\r\r").regex, "a.txt")

    # A BOM would otherwise become part of the first pattern, killing it.
    bom = IgnoreMatcher("/nonexistent", ["" => "\ufeff*.log\n"])
    @test isignored(bom, "a.log", false)
    @test !isignored(bom, "b.txt", false)

    # CRLF line endings throughout.
    crlf = IgnoreMatcher("/nonexistent", ["" => "*.log\r\n!keep.log\r\n"])
    @test isignored(crlf, "a.log", false)
    @test !isignored(crlf, "keep.log", false)
end

@testset "non-ASCII ignore patterns" begin
    # A byte-stepped loop would throw StringIndexError on any of these.
    @test occursin(ignore_glob_to_regex("café*", false), "café-notes")
    @test occursin(ignore_glob_to_regex("ünïcode?.txt", false), "ünïcodeX.txt")
    @test isignored(inline("日本/*.md"), "日本/notes.md", false)
end

@testset "nested .gitignore precedence" begin
    nested = IgnoreMatcher("/nonexistent", ["" => "*.jl", "src" => "!*.jl"])
    # The deeper file wins inside its own subtree only.
    @test !isignored(nested, "src/main.jl", false)
    @test isignored(nested, "lib/main.jl", false)
    # A sibling whose name merely starts with the prefix is not in that subtree.
    @test isignored(nested, "srclib/main.jl", false)

    # Several sources may share a prefix, and they apply in the order given,
    # which is how a directory's excludes and its `.gitignore` combine.
    layered = IgnoreMatcher("/nonexistent", ["" => "*.log", "" => "!keep.log"])
    @test !isignored(layered, "keep.log", false)
end
