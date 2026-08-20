# Guide

```@meta
CurrentModule = GitIgnore
```

## Installation

```julia
julia> using Pkg; Pkg.add("GitIgnore")
```

The package has no dependencies outside the standard library.

## Building a matcher

[`IgnoreMatcher`](@ref) compiles the rules in force under a directory, which
becomes the matcher's own notion of the top of the tree:

```julia
using GitIgnore

matcher = IgnoreMatcher("/path/to/repo")
```

The root need not be a repository. Every `.gitignore` and `.git/info/exclude`
found on the way down applies to its own subtree, the way git applies it, so a
matcher rooted at a home directory still honours each repository it contains.
Nothing above the root is ever consulted: a `.gitignore` up there governs a tree
the caller did not ask about.

Each directory's rules are read once, on first use, and cached in the matcher, so
repeated queries over one tree pay for a `.gitignore` at most once. Reading is
guarded by a lock, so one matcher can be shared across threads. A matcher is a
snapshot of what it has read, so build a new one to pick up an edited
`.gitignore`.

Pass `excludes = false` to honour `.gitignore` files only and skip
`.git/info/exclude`.

## Asking about one path

[`isignored`](@ref) takes a path that is either absolute or relative to the
matcher's root, and need not exist:

```julia
isignored(matcher, "build")            # true when `build/` is a rule
isignored(matcher, "build/out.o")      # true as well, taken from the parent
isignored(matcher, "build", false)     # false: the rule wants a directory
isignored(matcher, "src/main.jl")      # false
```

Two things are worth knowing about the answer.

Directory-ness matters, because a pattern with a trailing slash matches
directories only. The two-argument form asks the filesystem, treating a symlink
as a file however it resolves. Pass the third argument when the caller already
knows, which is also the only way to ask about a path that does not exist.

An excluded directory takes everything below it. Git cannot re-include a path
whose parent directory is excluded, so each parent is tested first and a match
there is the answer, which makes a query cost one test per path component.

## Walking a tree

[`walkfiltered`](@ref) walks depth first and prunes as it goes, calling the
callback once per surviving directory:

```julia
sources = String[]
result = walkfiltered(matcher, "/path/to/repo") do dir, dirs, files
    append!(sources, joinpath(dir, name) for name in files if endswith(name, ".jl"))
    return true                        # `false` stops the walk
end

result.completed                       # false when the callback stopped it
result.skipped                         # entries the rules removed
```

Pruning happens at the directory level, so an ignored directory is never
descended into. That is git's semantics, and it is why this is cheaper than
walking the whole tree and filtering afterwards.

`skipped` counts entries rather than files, so a pruned directory holding a
thousand files counts once. It exists so a caller can tell an empty result caused
by the ignore rules from one caused by its own pattern.

`.git` is dropped by name, which `skipgit = false` turns off. Git itself does not
report `.git` as ignored, so [`isignored`](@ref) does not either; the walk is
where it is skipped.

Symlinks are never followed, and a symlinked directory is reported as a file,
which is both git's view and `walkdir`'s default. A directory that cannot be read
is skipped rather than throwing, so one unreadable directory does not fail a
whole walk.

## Rules that are not on disk

The two-argument constructor takes `prefix => content` pairs, where `prefix` is
the declaring directory relative to the root and `content` is the text of an
ignore file. Such a matcher never touches the filesystem for rules:

```julia
inline = IgnoreMatcher(".", ["" => "*.log\n", "pkg" => "!keep.log\n"])
isignored(inline, "a.log", false)          # true
isignored(inline, "pkg/keep.log", false)   # false, the nested line wins
```

Several pairs may share a prefix, in which case they apply in the order given,
which is how a directory's excludes and its `.gitignore` combine.

`IgnoreMatcher(root, [])` therefore has no rules at all, which is the way to walk
a tree with only the walk's `.git` skipping in force:

```julia
walkfiltered(IgnoreMatcher(root, []), root) do dir, dirs, files
    return true                        # everything except .git
end
```

## Patterns that are understood

Everything in `gitignore(5)`, checked against the git binary: nested precedence,
`!` re-inclusion scoped to a subtree, the trailing slash for directories only,
`*` and `?` stopping at a separator, `**` crossing it, anchoring by a leading or
interior `/`, bracket expressions including POSIX classes, git's rule that only
unescaped trailing spaces are stripped, CRLF, a leading byte order mark, and the
inert-on-malformed-line behaviour that keeps one unusable line from costing the
whole file.

The exceptions are listed under [Fidelity to git](fidelity.md).
