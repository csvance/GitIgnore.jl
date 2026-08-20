# Shared ignore handling for the search tools (`ls`, `find`, `grep`).
#
# An agent pointed at a repository should see the repository, not its build
# output. `rg` solved that by honouring `.gitignore` and skipping `.git`, and
# these tools do the same, so `find` and `grep` agree with each other and with
# what a developer sees.
#
# Rules are read only from paths inside the tool's base directory: a `.gitignore`
# above it governs a tree the tools may not touch. Everything below is honoured,
# each file applying to its own subtree the way git applies it.

const IGNORE_FILE_NAME = ".gitignore"

# Repository-local excludes, which are part of "respect the ignore rules" even
# though they live outside any `.gitignore`. Per-user and system-wide excludes
# are not read: those depend on git configuration this package does not parse.
const GIT_EXCLUDE_PATH = (".git", "info", "exclude")

# `.git` is skipped even when ignore handling is off: it holds packed objects, so
# walking it is never what a caller meant, and a `.git` *file* is a worktree
# pointer rather than content.
always_ignored(name::AbstractString) = name == ".git"

normalize_relpath(path::AbstractString) = replace(path, '\\' => '/')

"""
One line of a `.gitignore`, compiled.

`regex` matches a path relative to the directory the pattern was declared in,
with `/` separators and no trailing slash. `negated` is a `!` prefix, which
re-includes a path an earlier pattern excluded. `dir_only` is a trailing slash,
which restricts the pattern to directories.
"""
struct IgnorePattern
    regex::Regex
    negated::Bool
    dir_only::Bool
end

"""
The patterns from one ignore file, plus `prefix`: the declaring directory
relative to the base directory, `""` for the base directory itself. A path is
tested against these patterns after `prefix` is stripped from it, which is what
makes a nested `.gitignore` apply to its own subtree only.
"""
struct IgnoreRules
    prefix::String
    patterns::Vector{IgnorePattern}
end

"""
Ignore rules in force for one directory, innermost last. `enabled` is false when
the caller asked to see ignored files, which leaves `rules` empty and stops
[`walk_filtered`](@ref) loading any more of them on the way down.
"""
struct IgnoreContext
    root::String
    enabled::Bool
    rules::Vector{IgnoreRules}
end

const IGNORE_REGEX_META = ('\\', '.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|', '*', '?')

print_regex_literal(io::IO, char::AbstractChar) =
    char in IGNORE_REGEX_META ? print(io, '\\', char) : print(io, char)

# Translate a bracket expression starting at `idx` (the `[`). Returns the
# character index just past the closing `]`, or nothing when the expression
# cannot be translated faithfully, which makes the whole pattern inert.
#
# `nothing` covers two cases, and git makes both inert too: an unterminated `[`,
# where git's `wildmatch` returns WM_ABORT_ALL so the pattern matches nothing,
# and a `[=equiv=]` or `[.collating.]` element, which PCRE does not implement.
# Guessing at either is worse than matching nothing, because a pattern that
# quietly matches the wrong set hides files the caller needed.
function translate_char_class(out::IO, pattern::AbstractString, idx::Int)
    last_idx = lastindex(pattern)
    cursor = nextind(pattern, idx)
    negated = false
    if cursor <= last_idx && (pattern[cursor] == '!' || pattern[cursor] == '^')
        negated = true
        cursor = nextind(pattern, cursor)
    end
    body = IOBuffer()
    at_start = true
    while cursor <= last_idx
        char = pattern[cursor]
        # A `]` in the first position is a literal member, not the terminator.
        if char == ']' && !at_start
            print(out, "[", negated ? "^" : "", String(take!(body)), "]")
            return nextind(pattern, cursor)
        end
        if char == '['
            # A POSIX class such as `[:digit:]` is legal in a gitignore pattern
            # and is also PCRE syntax, so it passes through verbatim. Escaping
            # the `[` instead would turn `[[:digit:]]` into a class of the six
            # characters in ":digit" followed by a literal `]`.
            after_posix = _copy_posix_class(body, pattern, cursor)
            if after_posix !== nothing
                cursor = after_posix
                at_start = false
                continue
            end
            _is_collating_element(pattern, cursor) && return nothing
        end
        if char == '\\'
            escaped = nextind(pattern, cursor)
            if escaped <= last_idx
                print(body, "\\", pattern[escaped])
                cursor = nextind(pattern, escaped)
                at_start = false
                continue
            end
        end
        # `-` passes through so ranges keep working; the rest of what a regex
        # class treats specially is escaped.
        char in ('\\', ']', '^', '[') ? print(body, "\\", char) : print(body, char)
        at_start = false
        cursor = nextind(pattern, cursor)
    end
    return nothing
end

# `[:name:]` at `cursor`: copy it through and return the index past it, or
# nothing when this is not one.
function _copy_posix_class(body::IO, pattern::AbstractString, cursor::Int)
    last_idx = lastindex(pattern)
    open_colon = nextind(pattern, cursor)
    (open_colon <= last_idx && pattern[open_colon] == ':') || return nothing
    probe = nextind(pattern, open_colon)
    name = IOBuffer()
    while probe <= last_idx
        if pattern[probe] == ':'
            close_bracket = nextind(pattern, probe)
            (close_bracket <= last_idx && pattern[close_bracket] == ']') || return nothing
            print(body, "[:", String(take!(name)), ":]")
            return nextind(pattern, close_bracket)
        end
        isletter(pattern[probe]) || return nothing
        print(name, pattern[probe])
        probe = nextind(pattern, probe)
    end
    return nothing
end

# `[=x=]` or `[.x.]`, which git supports and PCRE does not.
function _is_collating_element(pattern::AbstractString, cursor::Int)
    last_idx = lastindex(pattern)
    marker = nextind(pattern, cursor)
    marker <= last_idx || return false
    return pattern[marker] == '=' || pattern[marker] == '.'
end

"""
    ignore_glob_to_regex(pattern, anchored) -> Union{Nothing, Regex}

Compile a gitignore pattern body, with any `!` prefix and trailing `/` already
stripped. `anchored` patterns match from the declaring directory; the rest match
at any depth, which is git's rule for a pattern containing no `/`.

`*` and `?` stop at a separator; `**/`, `/**/` and a trailing `/**` cross them.
Stepping is by character index rather than by byte, because a byte-stepped loop
throws `StringIndexError` on a non-ASCII pattern.

Returns nothing for a pattern git treats as inert, matching nothing: an
untranslatable bracket expression, a trailing lone backslash, or a body whose
regex will not compile. A `.gitignore` is untrusted input from whatever
repository the caller happens to be standing in, and one unusable line must cost
that line only, not the whole tool.
"""
function ignore_glob_to_regex(pattern::AbstractString, anchored::Bool)
    out = IOBuffer()
    print(out, "^")
    anchored || print(out, "(?:.*/)?")
    first_idx = firstindex(pattern)
    last_idx = lastindex(pattern)
    idx = first_idx
    while idx <= last_idx
        char = pattern[idx]
        next_idx = nextind(pattern, idx)
        if char == '\\'
            # A pattern ending in a lone backslash is inert in git, not a literal
            # backslash: `wildmatch` aborts on the unterminated escape.
            next_idx > last_idx && return nothing
            print_regex_literal(out, pattern[next_idx])
            idx = nextind(pattern, next_idx)
            continue
        elseif char == '*'
            run_end = idx
            stars = 0
            while run_end <= last_idx && pattern[run_end] == '*'
                stars += 1
                run_end = nextind(pattern, run_end)
            end
            segment_start = idx == first_idx || pattern[prevind(pattern, idx)] == '/'
            followed_by_slash = run_end <= last_idx && pattern[run_end] == '/'
            if stars >= 2 && segment_start && followed_by_slash
                # `**/` — zero or more leading path segments.
                print(out, "(?:.*/)?")
                idx = nextind(pattern, run_end)
            elseif stars >= 2 && segment_start && run_end > last_idx
                # A trailing `**` — everything below this point.
                print(out, ".*")
                idx = run_end
            else
                # Anywhere else, consecutive asterisks are just an asterisk.
                print(out, "[^/]*")
                idx = run_end
            end
            continue
        elseif char == '?'
            print(out, "[^/]")
            idx = next_idx
            continue
        elseif char == '['
            after_class = translate_char_class(out, pattern, idx)
            after_class === nothing && return nothing
            idx = after_class
            continue
        end
        print_regex_literal(out, char)
        idx = next_idx
    end
    print(out, "\$")
    return try
        Regex(String(take!(out)))
    catch
        # An invalid range such as `[c-a]` is a PCRE compilation error, which git
        # leaves inert rather than fatal.
        nothing
    end
end

# Strip the trailing whitespace git strips, which is unescaped SPACES only. A
# backslash before the last space quotes it, so `foo\ ` really does mean a name
# ending in a space. Tabs are deliberately not stripped: git's
# `trim_trailing_spaces` switches on ' ' alone, so a pattern ending in a tab
# matches a filename ending in a tab.
function strip_unescaped_trailing_space(line::AbstractString)
    stop = lastindex(line)
    while stop >= firstindex(line) && line[stop] == ' '
        previous = prevind(line, stop)
        # An odd number of backslashes immediately before the space quotes it.
        backslashes = 0
        probe = previous
        while probe >= firstindex(line) && line[probe] == '\\'
            backslashes += 1
            probe = prevind(line, probe)
        end
        isodd(backslashes) && break
        stop = previous
    end
    return stop < firstindex(line) ? "" : line[firstindex(line):stop]
end

"""
    parse_ignore_line(line) -> Union{Nothing, IgnorePattern}

Compile one `.gitignore` line, or return nothing for a blank line or a comment.
Leading whitespace is significant to git and is kept.
"""
function parse_ignore_line(line::AbstractString)
    # Exactly one CR, which is the CRLF that `eachsplit` left behind. Stripping
    # every trailing CR would turn `a.txt\r\r` into the pattern `a.txt`, where
    # git reads it as `a.txt\r` and matches nothing.
    body = strip_unescaped_trailing_space(endswith(line, '\r') ? chop(line) : line)
    isempty(body) && return nothing
    startswith(body, "#") && return nothing
    negated = false
    if startswith(body, "!")
        negated = true
        body = body[nextind(body, firstindex(body)):end]
    elseif startswith(body, "\\#") || startswith(body, "\\!")
        # An escaped leading `#` or `!` is a literal one.
        body = body[nextind(body, firstindex(body)):end]
    end
    isempty(body) && return nothing
    dir_only = endswith(body, "/")
    dir_only && (body = body[firstindex(body):prevind(body, lastindex(body))])
    isempty(body) && return nothing
    # A pattern with a separator left in it is anchored to the declaring
    # directory; one without matches a basename at any depth.
    anchored = occursin('/', body)
    startswith(body, "/") && (body = body[nextind(body, firstindex(body)):end])
    isempty(body) && return nothing
    regex = ignore_glob_to_regex(body, anchored)
    regex === nothing && return nothing
    return IgnorePattern(regex, negated, dir_only)
end

function load_ignore_patterns(path::AbstractString, prefix::AbstractString)
    content = try
        # `isfile` and the read are both inside the guard: a directory the process
        # cannot traverse makes even the stat throw EACCES, and probing for a
        # `.gitignore` must never be the thing that fails a tool call.
        isfile(path) ? read(path, String) : nothing
    catch
        nothing
    end
    content === nothing && return nothing
    # A BOM would otherwise become part of the first pattern, making it dead.
    startswith(content, '\ufeff') && (content = content[nextind(content, firstindex(content)):end])
    patterns = IgnorePattern[]
    for line in eachsplit(content, '\n')
        pattern = parse_ignore_line(line)
        pattern === nothing || push!(patterns, pattern)
    end
    isempty(patterns) && return nothing
    return IgnoreRules(String(prefix), patterns)
end

"""
    load_dir_rules(dir, prefix) -> Vector{IgnoreRules}

Everything `dir` contributes: its repository-local excludes first, then its
`.gitignore`, which is the precedence git gives them. A directory contributes
both because a repository nested below the base directory is still a repository,
and picking up its `.gitignore` but not its excludes would honour half its rules.
"""
function load_dir_rules(dir::AbstractString, prefix::AbstractString)
    rules = IgnoreRules[]
    excludes = load_ignore_patterns(joinpath(dir, GIT_EXCLUDE_PATH...), prefix)
    excludes === nothing || push!(rules, excludes)
    own = load_ignore_patterns(joinpath(dir, IGNORE_FILE_NAME), prefix)
    own === nothing || push!(rules, own)
    return rules
end

# A path relative to the ignore root, `/`-separated, "" for the root itself.
function root_relative(root::AbstractString, path::AbstractString)
    rel = normalize_relpath(relpath(abspath(path), abspath(root)))
    return rel == "." ? "" : rel
end

"""
    ignore_context(base, dir; enabled=true) -> IgnoreContext

Collect the ignore rules that apply inside `dir`: the base directory's excludes
and `.gitignore`, then every `.gitignore` on the way down to `dir`. `dir` must be
inside `base`, which the tools' path resolution has already checked.
"""
function ignore_context(base::AbstractString, dir::AbstractString; enabled::Bool = true)
    root = abspath(base)
    rules = IgnoreRules[]
    if enabled
        append!(rules, load_dir_rules(root, ""))
        prefix = ""
        path = root
        for segment in eachsplit(root_relative(root, dir), '/'; keepempty = false)
            # `..` cannot appear for a contained path, but a rule set built from
            # one would be nonsense, so stop rather than guess.
            segment == ".." && break
            prefix = isempty(prefix) ? String(segment) : "$(prefix)/$(segment)"
            path = joinpath(path, segment)
            append!(rules, load_dir_rules(path, prefix))
        end
    end
    return IgnoreContext(root, enabled, rules)
end

# The portion of `rel` that `rules` was written to match, or nothing when `rel`
# lies outside the declaring directory.
function strip_rules_prefix(rel::AbstractString, prefix::AbstractString)
    isempty(prefix) && return rel
    startswith(rel, prefix) || return nothing
    # `prefix` is a byte-wise prefix of `rel`, so its last index is a valid index
    # into `rel`; the character after it has to be the separator, or `prefix`
    # merely shares a name fragment with a sibling directory.
    boundary = nextind(rel, lastindex(prefix))
    boundary > lastindex(rel) && return nothing
    rel[boundary] == '/' || return nothing
    return rel[nextind(rel, boundary):end]
end

"""
    path_ignored(rules, rel, is_dir) -> Bool

Whether `rel`, a path relative to the ignore root, is excluded by `rules`.

Precedence follows git: a deeper `.gitignore` overrides a shallower one, and
within one file the last matching line wins, so both loops simply keep
overwriting the verdict.
"""
function path_ignored(rules::Vector{IgnoreRules}, rel::AbstractString, is_dir::Bool)
    ignored = false
    for rule_set in rules
        subject = strip_rules_prefix(rel, rule_set.prefix)
        subject === nothing && continue
        for pattern in rule_set.patterns
            pattern.dir_only && !is_dir && continue
            occursin(pattern.regex, subject) || continue
            ignored = !pattern.negated
        end
    end
    return ignored
end

"""
    is_ignored(ctx, rel, is_dir) -> Bool

Whether the entry at root-relative path `rel` should be hidden. `.git` is hidden
regardless of `ctx.enabled`; everything else is hidden only when `ctx.rules` say
so, and those are empty when the caller asked to see ignored files.
"""
function is_ignored(ctx::IgnoreContext, rel::AbstractString, is_dir::Bool)
    isempty(rel) && return false
    always_ignored(basename(rel)) && return true
    return path_ignored(ctx.rules, rel, is_dir)
end

# Each entry of `dir` as `(name, is_dir)`, in the alphabetical order `_readdirx`
# returns. Throws if the directory cannot be read; the walk decides what to do.
#
# `_readdirx` is what `Base.walkdir` gets its speed from: its entries carry the
# type the OS already reported for each dirent, so `isdir`/`islink` on one costs
# no stat call, where reading names with `readdir` and stat'ing each of them is
# several times slower on a tree with no rules in it at all.
dir_entries(dir::AbstractString) =
    Tuple{String,Bool}[(entry.name, _entry_is_dir(entry))
                       for entry in Base.Filesystem._readdirx(dir)]

# A symlink is a file whatever it points at, which is both `walkdir`'s default
# and git's view. An entry whose type cannot be determined counts as a file, so
# the walk reports it and moves on instead of throwing.
_entry_is_dir(entry) = !_probe(islink, entry, true) && _probe(isdir, entry, false)

_probe(f, entry, fallback::Bool) = try
    f(entry)
catch
    fallback
end

"""
    walk_filtered(f, ctx, start) -> (; completed::Bool, skipped::Int)

Walk `start` depth-first, pruning ignored entries, and call `f(dir, dirs, files)`
once per surviving directory with the surviving entry names. `f` returns `false`
to stop the walk, which makes `completed` false.

`skipped` counts the entries the ignore rules removed, so a caller can tell an
empty result caused by the rules from one caused by its own pattern. It counts
entries, not files: a pruned directory holding a thousand files counts once.

Pruning happens at the directory level, so an ignored directory is never
descended into. That matches git, where a rule inside an excluded directory
cannot re-include anything, and it is why the walk stays cheap on a tree with a
large build directory.

`start` itself is never pruned: a caller that names a path has asked for it, the
same way `rg dist/` searches `dist/`.
"""
function walk_filtered(f, ctx::IgnoreContext, start::AbstractString)
    start_dir = abspath(start)
    # Rules for `start` already include its own `.gitignore`; each descent adds
    # the child's, if it has one.
    pending = [(start_dir, root_relative(ctx.root, start_dir), ctx.rules)]
    skipped = 0
    while !isempty(pending)
        dir, dir_rel, rules = pop!(pending)
        entries = try
            dir_entries(dir)
        catch
            # A directory that cannot be read is skipped, matching the way the
            # tools already swallow unreadable files.
            continue
        end
        dirs = String[]
        files = String[]
        has_rules = !isempty(rules)
        for (name, is_dir) in entries
            # Checked on the name, before any path is built: this runs for every
            # entry in the tree, and on a tree with no rules at all it is the only
            # work the filter does.
            always_ignored(name) && continue
            if has_rules
                rel = isempty(dir_rel) ? name : "$(dir_rel)/$(name)"
                if path_ignored(rules, rel, is_dir)
                    skipped += 1
                    continue
                end
            end
            push!(is_dir ? dirs : files, name)
        end
        f(dir, dirs, files) === false && return (; completed = false, skipped)
        # Reversed, because the stack pops last-in first: this keeps the walk in
        # alphabetical order.
        for name in Iterators.reverse(dirs)
            child_rel = isempty(dir_rel) ? name : "$(dir_rel)/$(name)"
            child = joinpath(dir, name)
            nested = ctx.enabled ? load_dir_rules(child, child_rel) : IgnoreRules[]
            push!(pending, (child, child_rel, isempty(nested) ? rules : vcat(rules, nested)))
        end
    end
    return (; completed = true, skipped)
end
