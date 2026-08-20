# Compiling one `.gitignore` into matchable patterns. Every rule here is git's
# rule rather than the gitignore(5) prose, and `test/differential.jl` is what
# keeps it that way.

const IGNORE_FILE_NAME = ".gitignore"

# Repository-local excludes are part of honouring a repository's rules even
# though they live outside any `.gitignore`. Per-user and system-wide excludes
# need git configuration this package does not parse, so they are not read.
const GIT_EXCLUDE_PATH = (".git", "info", "exclude")

normalize_relpath(path::AbstractString) = replace(path, '\\' => '/')

"""
What a compiled pattern is matched against.

A pattern body with no `/` in it matches a basename at any depth, and no such
body can match a `/`: the translation only ever emits `[^/]*`, `[^/]`,
`(?!/)[...]` and escaped literals. So `^(?:.*/)?BODY\$` against a path is the same
question as `^BODY\$` against that path's last segment, and the cheap forms of
that question do not need a regex at all. The one unanchored body that can cross
a separator is one made of nothing but stars, which compiles to `.*`, so it stays
a path test.

- `PATH_REGEX`: match `regex` against the path, relative to the declaring
  directory. Anchored patterns and all-star bodies.
- `NAME_REGEX`: match `regex` against the entry's own name.
- `NAME_LITERAL`: the name equals `literal`. This is `Manifest.toml`, `build/`.
- `NAME_SUFFIX`: the name ends with `literal`. This is `*.log`, `*.o`.
"""
@enum PatternKind PATH_REGEX NAME_REGEX NAME_LITERAL NAME_SUFFIX

"""
One line of a `.gitignore`, compiled.

`regex` is always the faithful translation, and is what the cheaper `kind`s are
checked against when the differential suite compares the two. `negated` is a `!`
prefix, which re-includes a path an earlier pattern excluded. `dir_only` is a
trailing slash, which restricts the pattern to directories.
"""
struct IgnorePattern
    regex::Regex
    literal::String
    kind::PatternKind
    negated::Bool
    dir_only::Bool
end

"""
The patterns from one ignore file, plus `prefix`: the declaring directory
relative to the matcher root, `""` for the root itself. A path is tested against
these patterns after `prefix` is stripped from it, which is what makes a nested
`.gitignore` apply to its own subtree only.

`needs_path` is whether any of the patterns looks at the path rather than at the
entry's own name. Most ignore files hold none, and then a caller that already has
the name does not have to build a path at all.
"""
struct IgnoreRules
    prefix::String
    patterns::Vector{IgnorePattern}
    needs_path::Bool
end

const IGNORE_REGEX_META = ('\\', '.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|', '*', '?')

print_regex_literal(io::IO, char::AbstractChar) =
    char in IGNORE_REGEX_META ? print(io, '\\', char) : print(io, char)

# One member of a bracket expression, backslash escaped or not, with the index
# after it, or nothing for a dangling escape. An escape inside a class quotes a
# literal and nothing more: git reads `[a-\d]` as the range a to d, where a regex
# would read `\d` as the digit class.
function class_member(pattern::AbstractString, cursor::Int)
    last_idx = lastindex(pattern)
    cursor <= last_idx || return nothing
    if pattern[cursor] == '\\'
        escaped = nextind(pattern, cursor)
        escaped <= last_idx || return nothing
        return (pattern[escaped], nextind(pattern, escaped))
    end
    return (pattern[cursor], nextind(pattern, cursor))
end

const CLASS_META = ('\\', ']', '^', '[', '-')

print_class_literal(io::IO, char::AbstractChar) =
    char in CLASS_META ? print(io, '\\', char) : print(io, char)

# Translate a bracket expression starting at `idx` (the `[`), returning the index
# just past the closing `]`. Returns nothing for the two cases git makes inert
# too: an unterminated `[`, where git's `wildmatch` returns WM_ABORT_ALL, and a
# `[=equiv=]` or `[.collating.]` element, which PCRE does not implement. Guessing
# at either would quietly match the wrong set and hide files the caller needed.
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
    previous = nothing
    while cursor <= last_idx
        char = pattern[cursor]
        # A `]` in the first position is a literal member, not the terminator.
        if char == ']' && !at_start
            # No class matches a separator, whatever it holds: git matches with
            # WM_PATHNAME, one path component at a time. The lookahead carries
            # that rule over, and keeps a negated class from swallowing a `/`.
            print(out, "(?!/)[", negated ? "^" : "", String(take!(body)), "]")
            return nextind(pattern, cursor)
        end
        if char == '['
            # A POSIX class is legal in a gitignore pattern and is also PCRE
            # syntax, so it passes through verbatim. Escaping the `[` would turn
            # `[[:digit:]]` into the six characters of ":digit" plus a `]`.
            after_posix = copy_posix_class(body, pattern, cursor)
            if after_posix !== nothing
                cursor = after_posix
                at_start = false
                previous = nothing
                continue
            end
            is_collating_element(pattern, cursor) && return nothing
        end
        # `-` forms a range only between two members, which is git's rule too: a
        # leading `-`, a trailing one, and one just after a range are literals.
        if char == '-' && previous !== nothing
            after_dash = nextind(pattern, cursor)
            if after_dash <= last_idx && pattern[after_dash] != ']'
                endpoint = class_member(pattern, after_dash)
                endpoint === nothing && return nothing
                stop, cursor = endpoint
                # git compares each member literally as it reads it and applies
                # the range only on reaching the `-`, so a reversed range still
                # matches its own start character, which is already in `body`.
                if previous <= stop
                    print(body, '-')
                    print_class_literal(body, stop)
                end
                at_start = false
                previous = nothing
                continue
            end
        end
        member = class_member(pattern, cursor)
        member === nothing && return nothing
        char, cursor = member
        print_class_literal(body, char)
        at_start = false
        previous = char
    end
    return nothing
end

# `[:name:]` at `cursor`: copy it through and return the index past it, or
# nothing when this is not one.
function copy_posix_class(body::IO, pattern::AbstractString, cursor::Int)
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
function is_collating_element(pattern::AbstractString, cursor::Int)
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
that line only, not the whole walk.
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
                # `**/` is zero or more leading path segments.
                print(out, "(?:.*/)?")
                idx = nextind(pattern, run_end)
            elseif stars >= 2 && segment_start && run_end > last_idx
                # A trailing `**` is everything below this point.
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
# backslash before the last space quotes it, so `foo\ ` means a name ending in a
# space. Tabs stay: git's `trim_trailing_spaces` switches on ' ' alone.
function strip_unescaped_trailing_space(line::AbstractString)
    stop = lastindex(line)
    while stop >= firstindex(line) && line[stop] == ' '
        previous = prevind(line, stop)
        backslashes = 0
        probe = previous
        while probe >= firstindex(line) && line[probe] == '\\'
            backslashes += 1
            probe = prevind(line, probe)
        end
        # An odd number of backslashes immediately before the space quotes it.
        isodd(backslashes) && break
        stop = previous
    end
    return stop < firstindex(line) ? "" : line[firstindex(line):stop]
end

"""
    parse_ignore_line(line) -> Union{Nothing, IgnorePattern}

Compile one `.gitignore` line, or return nothing for a blank line, a comment, or
a line git treats as inert. Leading whitespace is significant to git and is kept.
"""
function parse_ignore_line(line::AbstractString)
    # Exactly one CR, the CRLF `eachsplit` left behind. Stripping every trailing
    # CR would read `a.txt\r\r` as `a.txt`, where git reads `a.txt\r`.
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
    kind, literal = classify_pattern(body, anchored)
    # A `NAME_` pattern is matched against one path segment, so it wants the
    # translation without the `(?:.*/)?` that lets a pattern float to any depth.
    regex = ignore_glob_to_regex(body, kind === PATH_REGEX ? anchored : true)
    regex === nothing && return nothing
    return IgnorePattern(regex, literal, kind, negated, dir_only)
end

const PATTERN_META = ('*', '?', '[', '\\')

has_meta(body::AbstractString) = any(char -> char in PATTERN_META, body)

# Which of the four ways to match this body, and the literal the cheap two need.
# See [`PatternKind`](@ref) for why the reduction is sound.
function classify_pattern(body::AbstractString, anchored::Bool)
    (anchored || all(==('*'), body)) && return (PATH_REGEX, "")
    has_meta(body) || return (NAME_LITERAL, String(body))
    if first(body) == '*'
        rest = body[nextind(body, firstindex(body)):end]
        has_meta(rest) || return (NAME_SUFFIX, String(rest))
    end
    return (NAME_REGEX, "")
end

"""
    parse_ignore_file(content, prefix) -> Union{Nothing, IgnoreRules}

Compile the text of one ignore file. Returns nothing when it contributes no
usable pattern, which lets a caller skip an empty rule set rather than carry it.
"""
function parse_ignore_file(content::AbstractString, prefix::AbstractString)
    # A BOM would otherwise become part of the first pattern, making it dead.
    startswith(content, '\ufeff') && (content = content[nextind(content, firstindex(content)):end])
    patterns = IgnorePattern[]
    for line in eachsplit(content, '\n')
        pattern = parse_ignore_line(line)
        pattern === nothing || push!(patterns, pattern)
    end
    isempty(patterns) && return nothing
    return IgnoreRules(
        String(prefix), patterns,
        any(pattern -> pattern.kind === PATH_REGEX, patterns)
    )
end

function load_ignore_patterns(path::AbstractString, prefix::AbstractString)
    content = try
        # `isfile` and the read are both inside the guard: a directory the
        # process cannot traverse makes even the stat throw EACCES.
        isfile(path) ? read(path, String) : nothing
    catch
        nothing
    end
    content === nothing && return nothing
    return parse_ignore_file(content, prefix)
end

"""
    load_dir_rules(dir, prefix; excludes=true, gitdir=true, ignorefile=true)
        -> Vector{IgnoreRules}

Everything `dir` contributes: its repository-local excludes first, then its
`.gitignore`, which is the precedence git gives them. A directory contributes
both because a repository nested below the matcher root is still a repository,
and picking up its `.gitignore` but not its excludes would honour half its rules.

`gitdir` and `ignorefile` say whether `.git` and `.gitignore` are present. A
caller holding a listing of `dir` already knows, and neither file can exist
unless its name is in that listing, so passing false saves a stat that was always
going to fail. `excludes=false` drops the exclude file whether it exists or not.
"""
function load_dir_rules(
        dir::AbstractString, prefix::AbstractString;
        excludes::Bool = true, gitdir::Bool = true,
        ignorefile::Bool = true
    )
    rules = IgnoreRules[]
    if excludes && gitdir
        found = load_ignore_patterns(joinpath(dir, GIT_EXCLUDE_PATH...), prefix)
        found === nothing || push!(rules, found)
    end
    if ignorefile
        found = load_ignore_patterns(joinpath(dir, IGNORE_FILE_NAME), prefix)
        found === nothing || push!(rules, found)
    end
    return rules
end

# Whether `rel` is inside the directory `prefix` was declared in.
function rules_apply(rel::AbstractString, prefix::AbstractString)
    isempty(prefix) && return true
    startswith(rel, prefix) || return false
    # `prefix` is a byte-wise prefix of `rel`, so its last index is valid there;
    # the next character must be the separator, or `prefix` merely shares a name
    # fragment with a sibling directory.
    boundary = nextind(rel, lastindex(prefix))
    boundary > lastindex(rel) && return false
    return rel[boundary] == '/'
end

# The portion of `rel` that `prefix`'s rules were written to match. A view, not a
# copy: this runs per rule set per entry on a tree with nested ignore files.
function strip_rules_prefix(rel::AbstractString, prefix::AbstractString)
    isempty(prefix) && return SubString(rel)
    return SubString(rel, nextind(rel, nextind(rel, lastindex(prefix))))
end

"""
    path_ignored(rules, rel, name, is_dir) -> Bool

Whether `rel`, a path relative to the matcher root whose last segment is `name`,
is excluded by `rules`.

Precedence follows git: a deeper `.gitignore` overrides a shallower one, and
within one file the last matching line wins, so both loops simply keep
overwriting the verdict. This decides one path against one rule stack and knows
nothing about `rel`'s parent directories; [`isignored`](@ref) adds git's rule
that an excluded directory cannot be re-included from below.

Most patterns are basename tests and never look at `rel` at all, which is what
[`PatternKind`](@ref) is for.
"""
function path_ignored(
        rules::Vector{IgnoreRules}, rel::AbstractString,
        name::AbstractString, is_dir::Bool
    )
    ignored = false
    for rule_set in rules
        rules_apply(rel, rule_set.prefix) || continue
        subject = strip_rules_prefix(rel, rule_set.prefix)
        for pattern in rule_set.patterns
            pattern.dir_only && !is_dir && continue
            kind = pattern.kind
            matched = if kind === NAME_LITERAL
                name == pattern.literal
            elseif kind === NAME_SUFFIX
                endswith(name, pattern.literal)
            elseif kind === NAME_REGEX
                occursin(pattern.regex, name)
            else
                occursin(pattern.regex, subject)
            end
            matched && (ignored = !pattern.negated)
        end
    end
    return ignored
end
