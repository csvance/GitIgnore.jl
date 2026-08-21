using Test
using GitIgnore

include("gitoracle.jl")

# Fixtures for the differential suite. Each lays out a tree and its ignore files;
# the harness then asks this package and `git check-ignore` about every path in
# it and fails on any disagreement.
const FIXTURES = Pair{String, Function}[
    "the classic build tree" => function (dir)
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "build", "deep"))
        mkpath(joinpath(dir, "vendor"))
        write(joinpath(dir, ".gitignore"), "build/\n*.log\n!keep.log\nvendor\n")
        for path in (
                "top.jl", "keep.log", "a.log", "src/main.jl", "src/app.log",
                "build/out.jl", "build/deep/x.jl", "vendor/lib.jl",
            )
            write(joinpath(dir, split(path, '/')...), "x")
        end
        return
    end,
    "a negation in a nested .gitignore" => function (dir)
        mkpath(joinpath(dir, "pkg", "local"))
        mkpath(joinpath(dir, "other"))
        write(joinpath(dir, ".gitignore"), "*.tmp\n")
        write(joinpath(dir, "pkg", ".gitignore"), "!important.tmp\nlocal/\n")
        for path in (
                "pkg/important.tmp", "pkg/scratch.tmp", "pkg/local/cache.jl",
                "other/important.tmp", "pkg/src.jl",
            )
            write(joinpath(dir, split(path, '/')...), "x")
        end
        return
    end,
    "a negation below an excluded directory" => function (dir)
        mkpath(joinpath(dir, "build", "deep"))
        write(joinpath(dir, ".gitignore"), "build/\n")
        write(joinpath(dir, "build", ".gitignore"), "!keep.txt\n!deep/\n")
        write(joinpath(dir, "build", "keep.txt"), "x")
        return write(joinpath(dir, "build", "deep", "x.jl"), "x")
    end,
    "symlinks are files however they resolve" => function (dir)
        mkpath(joinpath(dir, "real"))
        write(joinpath(dir, "real", "inner.jl"), "x")
        write(joinpath(dir, "plain.o"), "x")
        symlink(joinpath(dir, "real"), joinpath(dir, "link"))
        symlink(joinpath(dir, "plain.o"), joinpath(dir, "alias.o"))
        return write(joinpath(dir, ".gitignore"), "link/\n*.o\nreal/\n")
    end,
    "anchoring and the star forms" => function (dir)
        mkpath(joinpath(dir, "a", "b", "x"))
        mkpath(joinpath(dir, "logs", "deep"))
        mkpath(joinpath(dir, "docs", "guide", "build"))
        mkpath(joinpath(dir, "src", "logs"))
        write(
            joinpath(dir, ".gitignore"),
            "/top.jl\nsrc/*.jl\na/**/c\nlogs/**\ndocs/**/build/\n**/*.min.js\n"
        )
        for path in (
                "top.jl", "src/top.jl", "src/main.jl", "src/deep.txt",
                "a/c", "a/b/c", "a/b/x/c", "logs/a.log", "logs/deep/b.log",
                "docs/guide/build/index.html", "app.min.js", "src/app.min.js",
            )
            write(joinpath(dir, split(path, '/')...), "x")
        end
        return
    end,
    "the ignore-everything-then-re-include idiom" => function (dir)
        mkpath(joinpath(dir, "src", "deep"))
        mkpath(joinpath(dir, "extra"))
        write(joinpath(dir, ".gitignore"), "/*\n!/src/\n!*.jl\n!.gitignore\n")
        for path in (
                "top.jl", "top.txt", "src/main.jl", "src/notes.txt",
                "src/deep/x.jl", "extra/y.jl",
            )
            write(joinpath(dir, split(path, '/')...), "x")
        end
        return
    end,
    "repository-local excludes" => function (dir)
        mkpath(joinpath(dir, ".git", "info"))
        mkpath(joinpath(dir, "sub"))
        write(joinpath(dir, ".git", "info", "exclude"), "secret.txt\n*.bak\n")
        write(joinpath(dir, ".gitignore"), "*.log\n!secret.txt\n")
        for path in ("secret.txt", "public.txt", "notes.bak", "a.log", "sub/secret.txt")
            write(joinpath(dir, split(path, '/')...), "x")
        end
        return
    end,
    "whitespace, tabs, CRLF and a BOM" => function (dir)
        write(
            joinpath(dir, ".gitignore"),
            "\ufeff*.log\r\ntrailing.txt   \nspace\\ \ntabbed.txt\t\n#comment\n\\#hash\n"
        )
        for name in (
                "a.log", "trailing.txt", "space ", "tabbed.txt\t", "tabbed.txt",
                "#hash", "keep.txt",
            )
            write(joinpath(dir, name), "x")
        end
        return
    end,
    "bracket expressions and POSIX classes" => function (dir)
        write(
            joinpath(dir, ".gitignore"),
            "[abc].txt\n[]x].txt\n[!a-c].log\n[[:digit:]].dat\n[a-].md\n[\\]].dat\n"
        )
        for name in (
                "a.txt", "d.txt", "].txt", "x.txt", "a.log", "z.log",
                "1.dat", "a.dat", "].dat", "-.md", "a.md", "z.md",
            )
            write(joinpath(dir, name), "x")
        end
        return
    end,
    "bracket ranges a regex engine would reject" => function (dir)
        write(
            joinpath(dir, ".gitignore"),
            "[c-a].txt\n[a-\\d].txt\n[9-0].txt\n[\\w-z].txt\n[a-c-e].txt\nfoo\\\n[abc\na[b.txt\n*.log\n"
        )
        for name in (
                "a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "-.txt", "0.txt",
                "9.txt", "w.txt", "x.txt", "z.txt", "foo", "abc", "ab.txt", "b.log",
            )
            write(joinpath(dir, name), "x")
        end
        return
    end,
    "non-ASCII names and patterns" => function (dir)
        mkpath(joinpath(dir, "日本"))
        # `?` and a bracket expression each match one byte in git, so the
        # ones here land on a two byte character on purpose.
        write(
            joinpath(dir, ".gitignore"),
            "café*\n日本/*.md\nünïcode?.txt\ncaf?.txt\nsp??e.txt\n[!x].md\nq[é].txt\n"
        )
        for path in (
                "café-notes", "cafe-notes", "日本/notes.md", "日本/notes.jl",
                "ünïcodeX.txt", "ünïcode.txt", "café.txt", "cafx.txt",
                "spée.txt", "spxye.txt", "é.md", "a.md", "qé.txt",
            )
            write(joinpath(dir, split(path, '/')...), "x")
        end
        return
    end,
    "a directory and a file sharing one name" => function (dir)
        mkpath(joinpath(dir, "name"))
        mkpath(joinpath(dir, "sub"))
        write(joinpath(dir, ".gitignore"), "name/\nother\n")
        for path in ("name/inner.txt", "sub/name", "other", "sub/other")
            write(joinpath(dir, split(path, '/')...), "x")
        end
        mkpath(joinpath(dir, "otherdir"))
        return write(joinpath(dir, "otherdir", "x.txt"), "x")
    end,
    "a nested repository below the root" => function (dir)
        # git run from above a nested repository still reads its `.gitignore`,
        # so this package's per-directory rules must agree with it there.
        mkpath(joinpath(dir, "sub", "inner"))
        mkpath(joinpath(dir, "sub", ".git"))
        write(joinpath(dir, "sub", ".git", "HEAD"), "ref: refs/heads/main\n")
        write(joinpath(dir, ".gitignore"), "*.a\n")
        write(joinpath(dir, "sub", ".gitignore"), "*.b\n!keep.b\n")
        for path in ("outer.a", "sub/x.a", "sub/x.b", "sub/keep.b", "sub/inner/y.b")
            write(joinpath(dir, split(path, '/')...), "x")
        end
        return
    end,
    "deep trees with rules at several levels" => function (dir)
        write(joinpath(dir, ".gitignore"), "*.o\nbuild/\n")
        for level in 1:5
            path = joinpath(dir, fill("level", level)...)
            mkpath(path)
            write(joinpath(path, "a.o"), "x")
            write(joinpath(path, "a.jl"), "x")
            write(joinpath(path, ".gitignore"), level == 3 ? "!a.o\n*.jl\n" : "\n")
        end
        mkpath(joinpath(dir, "level", "build", "deep"))
        return write(joinpath(dir, "level", "build", "deep", "x.o"), "x")
    end,
]

# Patterns worth checking one at a time against the tree below. Anything whose
# git behaviour is not obvious from the manual page belongs here.
const TABLE_PATTERNS = [
    "a", "a/", "/a", "a/*", "a/**", "**/a", "*", "*/", "/*", "**", "**/",
    "*.txt", "!*.txt", "dir", "dir/", "dir/*", "dir/**", "/dir/a.txt",
    "dir/sub", "dir/sub/", "**/sub/", "*/sub", "*/*/a.txt", "**/*.txt",
    "?.txt", "??.txt", "[ab]", "[!ab]", "[a-c].txt", "[]a].txt", "[[:digit:]].txt",
    "[b-a].txt", "a[b.txt", "a\\", "\\a", "sp ace.txt", "sp?ce.txt", "sp*.txt",
    "café.txt", "caf*", "caf?.txt", "caf??.txt", "?.txt", "[!x].txt", "caf[é].txt",
    "logs/**/*.log", "logs/**", "**/deep/", "node_modules/",
    "!node_modules/", "ab", "ab/", "x.tmp", "*.tmp", "-.txt", "].txt", "[.txt",
    "a.txt   ", "a.txt\\ ", "#a.txt", "\\#a.txt", "!", "/", "a//b", "a/./b",
]

# A tiny linear congruential generator, so a generated sweep is reproducible
# without depending on the RNG stream of any particular Julia version.
mutable struct Lcg
    state::UInt64
end

# Returns 0 through `limit - 1`, so a caller indexing a collection adds it to
# `firstindex` rather than assuming the collection starts at 1.
function draw!(rng::Lcg, limit::Integer)
    rng.state = 6364136223846793005 * rng.state + 1442695040888963407
    return Int(rng.state >> 33) % limit
end

pick(rng::Lcg, choices) = choices[firstindex(choices) + draw!(rng, length(choices))]

const ATOMS = [
    "a", "b", "ab", "c.txt", "sub", "deep", "*", "**", "?", "*.txt",
    "[abc]", "[!abc]", "[a-c]", "[[:digit:]]", "[]a]", "[b-a]", "x*",
    "sp?ce.txt", "café*", "*.log", "node_modules",
]
const PREFIXES = ["", "/", "!", "!/", "**/", "!**/"]
const SUFFIXES = ["", "/", "/**"]

function generated_patterns(count::Integer; seed::UInt64 = 0x5eed_1917_2b0f_c001)
    rng = Lcg(seed)
    patterns = String[]
    while length(patterns) < count
        segments = [pick(rng, ATOMS) for _ in 1:(draw!(rng, 3) + 1)]
        pattern = pick(rng, PREFIXES) * join(segments, "/") * pick(rng, SUFFIXES)
        pattern in ("!", "/", "!/", "") || push!(patterns, pattern)
    end
    return patterns
end

# The tree every swept pattern is tested against: a few shapes at a few depths,
# plus the names that make bracket and whitespace patterns interesting.
function sweep_tree(dir::AbstractString)
    for sub in ("dir/sub", "other", "node_modules/pkg", "logs/deep", "ab", "deep/dir")
        mkpath(joinpath(dir, split(sub, '/')...))
    end
    for path in (
            "a", "b", "a.txt", "b.txt", "1.txt", "x.tmp", "-.txt", "].txt",
            "[.txt", "sp ace.txt", "café.txt", "é.txt", "dir/a.txt", "dir/a",
            "dir/sub/a.txt", "dir/sub/b", "other/a.txt", "ab/c.txt",
            "node_modules/pkg/index.js", "logs/a.log", "logs/deep/b.log",
            "deep/dir/a.txt", "deep/dir/x.tmp",
        )
        write(joinpath(dir, split(path, '/')...), "x")
    end
    return dir
end

@testset "differential against real git" begin
    if !GitOracle.available()
        @info "no usable git binary on PATH: the differential suite is skipped, " *
            "so this run proves nothing about fidelity to git"
    else
        @info "differential suite oracle: $(GitOracle.version())"

        for (name, build) in FIXTURES
            @testset "$name" begin
                GitOracle.withrepo() do repo
                    build(repo)
                    @test GitOracle.disagreements(repo) == String[]
                    @test GitOracle.walk_disagreements(repo) == String[]
                end
            end
        end

        @testset "table-driven pattern sweep" begin
            @test GitOracle.sweep(TABLE_PATTERNS, sweep_tree) == String[]
        end

        @testset "generated pattern sweep" begin
            patterns = generated_patterns(400)
            @test length(unique(patterns)) > 200
            @test GitOracle.sweep(patterns, sweep_tree) == String[]
        end

        # The same patterns one level down, with something at the root for a
        # negation to argue with. This is the region where libgit2 gets nested
        # precedence wrong, so it is the region worth sweeping hardest.
        @testset "swept in a nested .gitignore" begin
            @test GitOracle.sweep(
                TABLE_PATTERNS, sweep_tree;
                into = "dir/.gitignore",
                alongside = "*.txt\n*.log\n"
            ) == String[]
            @test GitOracle.sweep(
                generated_patterns(200; seed = 0x1234_5678_9abc_def1),
                sweep_tree; into = "dir/.gitignore",
                alongside = "*.txt\n*.log\n"
            ) == String[]
        end

        @testset "swept in .git/info/exclude" begin
            @test GitOracle.sweep(
                TABLE_PATTERNS, sweep_tree;
                into = ".git/info/exclude"
            ) == String[]
        end
    end
end

# The two divergences that are this package's reason to exist. libgit2 1.9, asked
# through `git_ignore_path_is_ignored` with a raw ccall on a fresh repository
# handle, disagrees with git 2.43 on both of these. Real git is the authority,
# and the expectations below are hardcoded so these tests still assert something
# on a machine with no git binary.
@testset "regression: a nested negation overrides a shallower pattern" begin
    # Root `*.tmp` plus `pkg/.gitignore` holding `!important.tmp`: git does not
    # ignore `pkg/important.tmp`. libgit2 does, because a negation in a nested
    # file fails to override the shallower pattern.
    mktempdir() do dir
        GitOracle.initrepo(dir)
        mkpath(joinpath(dir, "pkg"))
        mkpath(joinpath(dir, "other"))
        write(joinpath(dir, ".gitignore"), "*.tmp\n")
        write(joinpath(dir, "pkg", ".gitignore"), "!important.tmp\n")
        write(joinpath(dir, "pkg", "important.tmp"), "x")
        write(joinpath(dir, "pkg", "scratch.tmp"), "x")
        write(joinpath(dir, "other", "important.tmp"), "x")

        matcher = IgnoreMatcher(dir)
        @test !isignored(matcher, "pkg/important.tmp")
        @test isignored(matcher, "pkg/scratch.tmp")
        @test isignored(matcher, "other/important.tmp")

        if GitOracle.available()
            theirs = GitOracle.ignored_paths(
                dir, [
                    "pkg/important.tmp", "pkg/scratch.tmp",
                    "other/important.tmp",
                ]
            )
            @test theirs == Set(["pkg/scratch.tmp", "other/important.tmp"])
        end
    end
end

@testset "regression: a dir-only pattern does not match a symlink to a directory" begin
    # `.gitignore` holding `link/` where `link` is a symlink to a directory: git
    # does not ignore `link`, because a symlink is a file however it resolves.
    # libgit2 ignores it.
    mktempdir() do dir
        GitOracle.initrepo(dir)
        mkpath(joinpath(dir, "real"))
        write(joinpath(dir, "real", "inner.jl"), "x")
        symlink(joinpath(dir, "real"), joinpath(dir, "link"))
        write(joinpath(dir, ".gitignore"), "link/\n")

        matcher = IgnoreMatcher(dir)
        @test !isignored(matcher, "link")
        @test !isignored(matcher, "link", false)
        # The walk sees it as a file and does not follow it.
        seen = String[]
        walkfiltered(matcher, dir) do _dir, _dirs, files
            append!(seen, files)
            return true
        end
        @test "link" in seen
        @test count(==("inner.jl"), seen) == 1

        if GitOracle.available()
            @test isempty(GitOracle.ignored_paths(dir, ["link"]))
        end
    end
end
