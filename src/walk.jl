# The pruning walk. Pruning at the directory level is what makes honouring
# `.gitignore` cheaper than not honouring it on a tree with a build directory.

# `_readdirx` is what `Base.walkdir` gets its speed from: its entries carry the
# type the OS already reported for each dirent, so `isdir`/`islink` costs no stat
# call. It is not public API, so a Julia without it falls back to stat'ing.
const HAS_READDIRX = isdefined(Base.Filesystem, :_readdirx)

probe(f, subject, fallback::Bool) = try
    f(subject)
catch
    fallback
end

# A symlink is a file whatever it points at, which is both `walkdir`'s default and
# git's view. An entry whose type cannot be determined counts as a file, so the
# walk reports it and moves on instead of throwing.
entry_is_dir(entry) = !probe(islink, entry, true) && probe(isdir, entry, false)
path_is_dir(path::AbstractString) = entry_is_dir(path)

# A listing of `dir`: each entry as `(name, is_dir)`, sorted, which is what both
# listing functions return by default, plus whether `.git` and `.gitignore` are
# among the names. The two flags come free here and save the caller a stat each.
# Throws if the directory cannot be read; the walk decides what to do.
#
# `readdirx` is a parameter only so the slow path can be tested on a Julia that
# still has the fast one.
function dir_entries(dir::AbstractString, readdirx::Bool = HAS_READDIRX)
    entries = Tuple{String,Bool}[]
    gitdir = false
    ignorefile = false
    if readdirx
        for entry in Base.Filesystem._readdirx(dir)
            name = entry.name
            name == ".git" && (gitdir = true)
            name == IGNORE_FILE_NAME && (ignorefile = true)
            push!(entries, (name, entry_is_dir(entry)))
        end
    else
        for name in readdir(dir)
            name == ".git" && (gitdir = true)
            name == IGNORE_FILE_NAME && (ignorefile = true)
            push!(entries, (name, path_is_dir(joinpath(dir, name))))
        end
    end
    return (; entries, gitdir, ignorefile)
end

"""
    walkfiltered(f, matcher, start=ignoreroot(matcher); skipgit=true)
        -> (; completed::Bool, skipped::Int)

Walk `start` depth first, pruning ignored entries, and call `f(dir, dirs, files)`
once per surviving directory with the surviving entry names, `dir` absolute. `f`
returns `false` to stop the walk, which makes `completed` false. `start` is the
matcher's root by default, and is otherwise either absolute or relative to that
root, which it has to be inside.

Pruning happens at the directory level, so an ignored directory is never
descended into. That is git's semantics, where a rule inside an excluded
directory cannot re-include anything, and it is the reason this walk is cheaper
than walking the whole tree and filtering afterwards.

`skipped` counts the entries the ignore rules removed, so a caller can tell an
empty result caused by the rules from one caused by its own pattern. It counts
entries, not files: a pruned directory holding a thousand files counts once.
Entries removed by `skipgit` are not counted, because nothing about a repository
was hidden from the caller.

`skipgit` drops any entry named `.git`. It holds packed objects, so walking it is
never what a caller meant, and a `.git` *file* is a worktree pointer rather than
content. Git itself does not report `.git` as ignored, so [`isignored`](@ref) does
not either; this is where it is skipped.

Symlinks are never followed, and a symlinked directory is reported as a file.
`start` itself is never pruned: a caller that names a path has asked for it, the
same way `rg dist/` searches `dist/`.

A directory that cannot be read is skipped rather than throwing, which keeps one
unreadable directory from failing a whole walk.

# Examples
```julia
matcher = IgnoreMatcher(repo)
sources = String[]
walkfiltered(matcher, repo) do dir, dirs, files
    append!(sources, joinpath(dir, f) for f in files if endswith(f, ".jl"))
    return true
end
```
"""
function walkfiltered(f, matcher::IgnoreMatcher,
                      start::AbstractString = ignoreroot(matcher);
                      skipgit::Bool = true)
    segments = root_segments(matcher, start)
    start_dir = isempty(segments) ? matcher.root : joinpath(matcher.root, segments...)
    start_rel = join(segments, '/')
    # Each directory's own rules are loaded when it is reached rather than when it
    # is queued, so the listing can answer whether there is anything to load.
    pending = [(start_dir, start_rel, inherited_stack(matcher, segments))]
    skipped = 0
    while !isempty(pending)
        dir, dir_rel, inherited = pop!(pending)
        listing = try
            dir_entries(dir)
        catch
            continue
        end
        own = dir_rules_listed(matcher, dir_rel, dir, listing)
        rules = isempty(own) ? inherited : vcat(inherited, own)
        dirs = String[]
        files = String[]
        has_rules = !isempty(rules)
        for (name, is_dir) in listing.entries
            # Checked on the name, before any path is built: on a tree with no
            # rules at all this is the only work the filter does.
            skipgit && name == ".git" && continue
            if has_rules
                rel = isempty(dir_rel) ? name : "$(dir_rel)/$(name)"
                if path_ignored(rules, rel, name, is_dir)
                    skipped += 1
                    continue
                end
            end
            push!(is_dir ? dirs : files, name)
        end
        f(dir, dirs, files) === false && return (; completed = false, skipped)
        # Reversed, because the stack pops last in first: this keeps the walk in
        # the same order a caller sees the names in.
        for name in Iterators.reverse(dirs)
            child_rel = isempty(dir_rel) ? name : "$(dir_rel)/$(name)"
            push!(pending, (joinpath(dir, name), child_rel, rules))
        end
    end
    return (; completed = true, skipped)
end
