# The public entry point: a rooted, lazily populated view of a tree's ignore
# rules.

const NO_RULES = IgnoreRules[]

"""
    IgnoreMatcher(root; excludes=true) -> IgnoreMatcher
    IgnoreMatcher(root, sources) -> IgnoreMatcher

The ignore rules in force under `root`, which becomes the matcher's own notion of
the top of the tree.

Rules are read only from `root` and below. A `.gitignore` above `root` governs a
tree the caller did not ask about and is never consulted, and neither is
`core.excludesFile` nor any other per-user or system-wide exclude, because
reading those needs git configuration this package does not parse. `root` need
not be a repository: every `.gitignore` and `.git/info/exclude` found on the way
down applies to its own subtree, the way git applies it, so a matcher rooted at a
home directory still honours each repository it contains.

Each directory's rules are read once, on first use, and cached in the matcher, so
repeated queries over one tree pay for a `.gitignore` at most once. Reading is
guarded by a lock, which makes one matcher safe to share across threads.

Pass `excludes=false` to skip `.git/info/exclude` and honour `.gitignore` files
only.

The two-argument form takes rules the caller already holds instead of reading any:
`sources` is a collection of `prefix => content` pairs, where `prefix` is the
declaring directory relative to `root` (`""` for `root` itself) and `content` is
the text of an ignore file. Several pairs may share a prefix, in which case they
apply in the order given. Such a matcher never touches the filesystem for rules,
which makes it useful for testing pattern semantics and for a caller whose ignore
rules do not live on disk. `IgnoreMatcher(root, [])` therefore has no rules at
all, which is the way to walk a tree with only [`walkfiltered`](@ref)'s `.git`
skipping in force.

# Examples
```julia
matcher = IgnoreMatcher("/path/to/repo")
isignored(matcher, "build/out.o")

inmemory = IgnoreMatcher(".", ["" => "*.log\\n", "pkg" => "!keep.log\\n"])
isignored(inmemory, "pkg/keep.log", false)
```

See also [`isignored`](@ref), [`walkfiltered`](@ref).
"""
struct IgnoreMatcher
    root::String
    excludes::Bool
    fromdisk::Bool
    dircache::Dict{String, Vector{IgnoreRules}}
    cachelock::ReentrantLock
end

function IgnoreMatcher(root::AbstractString; excludes::Bool = true)
    return IgnoreMatcher(
        abspath(String(root)), excludes, true,
        Dict{String, Vector{IgnoreRules}}(), ReentrantLock()
    )
end

function IgnoreMatcher(root::AbstractString, sources)
    cache = Dict{String, Vector{IgnoreRules}}()
    for source in sources
        prefix = normalize_relpath(String(first(source)))
        prefix = prefix == "." ? "" : rstrip(prefix, '/')
        rules = parse_ignore_file(String(last(source)), prefix)
        rules === nothing && continue
        push!(get!(() -> IgnoreRules[], cache, prefix), rules)
    end
    return IgnoreMatcher(abspath(String(root)), true, false, cache, ReentrantLock())
end

function Base.show(io::IO, matcher::IgnoreMatcher)
    return print(
        io, "IgnoreMatcher(", repr(matcher.root),
        matcher.fromdisk ? "" : ", <explicit rules>", ")"
    )
end

"""
    ignoreroot(matcher) -> String

The absolute path the matcher's rules and relative paths are anchored to.
"""
ignoreroot(matcher::IgnoreMatcher) = matcher.root

# What the directory at `prefix` itself contributes, read once and cached. A
# directory with no ignore file caches an empty vector, so a second query over
# the same tree does not stat for it again.
function dir_rules(matcher::IgnoreMatcher, prefix::AbstractString)
    return cached_dir_rules(matcher, prefix) do
        dir = isempty(prefix) ? matcher.root :
            joinpath(matcher.root, split(prefix, '/')...)
        load_dir_rules(dir, prefix; excludes = matcher.excludes)
    end
end

"""
    dir_rules_listed(matcher, prefix, dir, listing) -> Vector{IgnoreRules}

The same thing, for a caller that has just listed `dir` and so already knows
whether an ignore file is there. That turns two stat calls per directory into two
string comparisons, which on a tree of a few thousand directories is the largest
single cost in the walk, and more so on a network filesystem.
"""
function dir_rules_listed(
        matcher::IgnoreMatcher, prefix::AbstractString,
        dir::AbstractString, listing
    )
    return cached_dir_rules(matcher, prefix) do
        load_dir_rules(
            dir, prefix; excludes = matcher.excludes,
            gitdir = listing.gitdir, ignorefile = listing.ignorefile
        )
    end
end

# `load` runs only on a miss, which is what keeps the path building out of the
# common case: the walk already holds the directory path, and a query does not
# need one unless it is about to read.
function cached_dir_rules(load, matcher::IgnoreMatcher, prefix::AbstractString)
    # An explicit matcher was handed its rules and must never read the tree.
    matcher.fromdisk || return get(matcher.dircache, prefix, NO_RULES)
    return lock(matcher.cachelock) do
        get!(load, matcher.dircache, prefix)
    end
end

# The path split into segments, with the forms that mean the same thing collapsed.
# `..` is rejected rather than resolved: resolving it textually is wrong as soon
# as a symlink is involved, and resolving it physically would let a query escape
# the root the caller established.
function root_segments(matcher::IgnoreMatcher, path::AbstractString)
    text = normalize_relpath(String(path))
    if isabspath(path)
        text = normalize_relpath(relpath(abspath(String(path)), matcher.root))
    end
    segments = String[]
    for segment in eachsplit(text, '/'; keepempty = false)
        segment == "." && continue
        segment == ".." && throw(
            ArgumentError(
                "path $(repr(String(path))) is not inside the matcher root $(repr(matcher.root))"
            )
        )
        push!(segments, String(segment))
    end
    return segments
end

# The rule stack in force in the PARENT of the directory named by `segments`,
# innermost last. The directory's own rules are left out because the walk picks
# those up from its listing, and adding them here would load them twice. One
# vector, appended to on the way down, because the stack only ever grows.
function inherited_stack(matcher::IgnoreMatcher, segments::Vector{String})
    stack = IgnoreRules[]
    isempty(segments) && return stack
    append!(stack, dir_rules(matcher, ""))
    prefix = ""
    for index in 1:(length(segments) - 1)
        prefix = isempty(prefix) ? segments[index] : "$(prefix)/$(segments[index])"
        append!(stack, dir_rules(matcher, prefix))
    end
    return stack
end

"""
    isignored(matcher, path) -> Bool
    isignored(matcher, path, is_dir::Bool) -> Bool

Whether `path` is excluded by the rules `matcher` holds, matching what
`git check-ignore` reports for the same tree.

`path` is either absolute or relative to the matcher's root, and need not exist.
A path containing `..` is rejected, and so is an absolute path outside the root.

Directory-ness matters, because a pattern with a trailing slash matches
directories only. The two-argument form asks the filesystem, treating a symlink
as a file however it resolves and a path that cannot be stat'ed as a file, which
is both git's view and `walkdir`'s. Pass `is_dir` when the caller already knows,
which is also the only way to ask about a path that does not exist.

An excluded directory takes everything below it: git cannot re-include a path
whose parent directory is excluded, so each parent is tested first and a match
there is the answer. That makes `isignored` cost one test per path component.

`.git` is not special here. Git does not report it as ignored either, since it is
never a candidate for tracking in the first place; [`walkfiltered`](@ref) is what
skips it.

# Examples
```julia
matcher = IgnoreMatcher(repo)
isignored(matcher, "build")            # true when `build/` is a rule
isignored(matcher, "build/out.o")      # true as well, from the parent
isignored(matcher, "build", false)     # false: the rule wants a directory
```
"""
function isignored(matcher::IgnoreMatcher, path::AbstractString, is_dir::Bool)
    segments = root_segments(matcher, path)
    isempty(segments) && return false
    stack = copy(dir_rules(matcher, ""))
    rel = ""
    for index in 1:(length(segments) - 1)
        rel = isempty(rel) ? segments[index] : "$(rel)/$(segments[index])"
        path_ignored(stack, rel, segments[index], true) && return true
        append!(stack, dir_rules(matcher, rel))
    end
    rel = isempty(rel) ? segments[end] : "$(rel)/$(segments[end])"
    return path_ignored(stack, rel, segments[end], is_dir)
end

isignored(matcher::IgnoreMatcher, path::AbstractString) =
    isignored(
    matcher, path, path_is_dir(
        isabspath(path) ? String(path) :
            joinpath(matcher.root, String(path))
    )
)
