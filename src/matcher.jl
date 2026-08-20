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
    dircache::Dict{String,Vector{IgnoreRules}}
    cachelock::ReentrantLock
end

IgnoreMatcher(root::AbstractString; excludes::Bool = true) =
    IgnoreMatcher(abspath(String(root)), excludes, true,
                  Dict{String,Vector{IgnoreRules}}(), ReentrantLock())

function IgnoreMatcher(root::AbstractString, sources)
    cache = Dict{String,Vector{IgnoreRules}}()
    for source in sources
        prefix = normalize_relpath(String(first(source)))
        prefix = prefix == "." ? "" : rstrip(prefix, '/')
        rules = parse_ignore_file(String(last(source)), prefix)
        rules === nothing && continue
        push!(get!(() -> IgnoreRules[], cache, prefix), rules)
    end
    return IgnoreMatcher(abspath(String(root)), true, false, cache, ReentrantLock())
end

Base.show(io::IO, matcher::IgnoreMatcher) =
    print(io, "IgnoreMatcher(", repr(matcher.root),
          matcher.fromdisk ? "" : ", <explicit rules>", ")")

"""
    ignoreroot(matcher) -> String

The absolute path the matcher's rules and relative paths are anchored to.
"""
ignoreroot(matcher::IgnoreMatcher) = matcher.root

# What the directory at `prefix` itself contributes, read once and cached. A
# directory with no ignore file caches an empty vector, so a second query over
# the same tree does not stat for it again.
function dir_rules(matcher::IgnoreMatcher, prefix::AbstractString)
    matcher.fromdisk || return get(matcher.dircache, prefix, NO_RULES)
    return lock(matcher.cachelock) do
        get!(matcher.dircache, prefix) do
            dir = isempty(prefix) ? matcher.root :
                  joinpath(matcher.root, split(prefix, '/')...)
            matcher.excludes ? load_dir_rules(dir, prefix) :
                               own_dir_rules(dir, prefix)
        end
    end
end

function own_dir_rules(dir::AbstractString, prefix::AbstractString)
    own = load_ignore_patterns(joinpath(dir, IGNORE_FILE_NAME), prefix)
    return own === nothing ? IgnoreRules[] : IgnoreRules[own]
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
        segment == ".." && throw(ArgumentError(
            "path $(repr(String(path))) is not inside the matcher root $(repr(matcher.root))"))
        push!(segments, String(segment))
    end
    return segments
end

# The rule stack in force *inside* the directory named by `segments`, innermost
# last. One vector, appended to on the way down, because the stack only ever
# grows as the walk descends.
function rule_stack(matcher::IgnoreMatcher, segments::Vector{String})
    stack = copy(dir_rules(matcher, ""))
    prefix = ""
    for segment in segments
        prefix = isempty(prefix) ? segment : "$(prefix)/$(segment)"
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
        path_ignored(stack, rel, true) && return true
        append!(stack, dir_rules(matcher, rel))
    end
    rel = isempty(rel) ? segments[end] : "$(rel)/$(segments[end])"
    return path_ignored(stack, rel, is_dir)
end

isignored(matcher::IgnoreMatcher, path::AbstractString) =
    isignored(matcher, path, path_is_dir(isabspath(path) ? String(path) :
                                        joinpath(matcher.root, String(path))))
