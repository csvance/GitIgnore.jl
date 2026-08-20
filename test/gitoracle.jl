# The oracle for the differential tests: the real `git` binary.
#
# Every call runs with the user's git configuration neutralised. A global
# `core.excludesFile` would otherwise make git ignore files this package never
# reads, and the disagreement would be the harness's fault rather than a bug.

module GitOracle

using Test
using GitIgnore

const GIT = Sys.which("git")

# A fake home, so no per-user ignore file or config reaches the oracle.
const SANDBOX_HOME = mktempdir(; cleanup = true)

gitenv() = [
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_SYSTEM" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "HOME" => SANDBOX_HOME,
    "XDG_CONFIG_HOME" => SANDBOX_HOME,
    "GIT_TERMINAL_PROMPT" => "0",
]

function available()
    GIT === nothing && return false
    return try
        success(setenv(`$(GIT) --version`, gitenv()))
    catch
        false
    end
end

version() = GIT === nothing ? "absent" :
    strip(read(setenv(`$(GIT) --version`, gitenv()), String))

"""
    withrepo(f) -> whatever `f` returns

Initialise a temporary git repository and call `f(dir)` on it, removing it
afterwards. The temporary directory is on local disk rather than under the
package, which is what keeps a per-path subprocess comparison affordable.
"""
function withrepo(f)
    return mktempdir() do dir
        initrepo(dir)
        return f(dir)
    end
end

"""
    initrepo(dir)

Make `dir` a repository the oracle can be asked about, or do nothing when there
is no git binary. A test that asserts hardcoded verdicts calls this so the same
fixture can be cross-checked against git when git is there.
"""
initrepo(dir::AbstractString) =
    available() && run(setenv(`$(GIT) init -q -b main $(dir)`, gitenv()))

# Every path under `repo` as `(relative, is_dir)`, including ignored ones and
# everything inside them, because a disagreement inside a pruned directory is
# still a disagreement. `.git` is reported but not descended into: git answers
# for `.git` itself and refuses paths beyond a symlink, so neither is followed.
function tree_paths(repo::AbstractString)
    found = Tuple{String, Bool}[]
    stack = [""]
    while !isempty(stack)
        prefix = pop!(stack)
        dir = isempty(prefix) ? repo : joinpath(repo, split(prefix, '/')...)
        for name in readdir(dir)
            rel = isempty(prefix) ? name : "$(prefix)/$(name)"
            full = joinpath(dir, name)
            is_dir = !islink(full) && isdir(full)
            push!(found, (rel, is_dir))
            is_dir && name != ".git" && push!(stack, rel)
        end
    end
    sort!(found; by = first)
    return found
end

"""
    ignored_paths(repo, paths) -> Set{String}

Which of `paths` git considers ignored. `git check-ignore` without `-v` prints
exactly the excluded paths: a path matched by a negated pattern is not printed,
and neither is one no pattern touches, so the output is the answer rather than
something to interpret. `--no-index` keeps the index out of it, and one
invocation covers every path.
"""
function ignored_paths(repo::AbstractString, paths::AbstractVector{<:AbstractString})
    isempty(paths) && return Set{String}()
    cmd = ignorestatus(
        setenv(
            Cmd(`$(GIT) check-ignore --no-index --stdin -z`; dir = repo),
            gitenv()
        )
    )
    out, err = IOBuffer(), IOBuffer()
    input = IOBuffer(join(paths, '\0') * '\0')
    process = run(pipeline(cmd; stdin = input, stdout = out, stderr = err))
    # 0 is "some path is ignored" and 1 is "none is"; anything else is a real
    # failure and must not be read as "nothing is ignored".
    process.exitcode in (0, 1) ||
        error("git check-ignore exited $(process.exitcode): $(String(take!(err)))")
    return Set{String}(split(String(take!(out)), '\0'; keepempty = false))
end

# Why git ruled the way it did, for a failure message.
function explain(repo::AbstractString, path::AbstractString)
    cmd = ignorestatus(
        setenv(
            Cmd(`$(GIT) check-ignore --no-index -v -- $(path)`; dir = repo),
            gitenv()
        )
    )
    out = IOBuffer()
    run(pipeline(cmd; stdout = out, stderr = devnull))
    detail = strip(String(take!(out)))
    return isempty(detail) ? "no pattern matched" : detail
end

"""
    disagreements(repo; kwargs...) -> Vector{String}

Compare this package with git for every path under `repo`, and describe each
verdict they differ on. Empty means they agree, which is what the tests assert,
and each entry carries git's own explanation so a failure says what to look at.
"""
function disagreements(repo::AbstractString; kwargs...)
    paths = tree_paths(repo)
    theirs = ignored_paths(repo, first.(paths))
    matcher = IgnoreMatcher(repo; kwargs...)
    report = String[]
    for (rel, is_dir) in paths
        mine = isignored(matcher, rel, is_dir)
        mine == (rel in theirs) && continue
        push!(
            report, string(
                rel, is_dir ? "/" : "", ": GitIgnore says ",
                mine ? "ignored" : "not ignored",
                ", git says ", mine ? "not ignored" : "ignored",
                " (", explain(repo, rel), ")"
            )
        )
    end
    return report
end

"""
    walk_disagreements(repo) -> Vector{String}

Compare the pruning walk's surviving set with git's, and describe each entry they
differ on.

The walk threads a rule stack down the tree while `isignored` walks the parents of
one path, so they are different code reaching the same answer, and only one of the
two is covered by [`disagreements`](@ref). A path survives the walk exactly when
git reports neither it nor any parent as ignored, `.git` aside, which the walk
drops at any depth whatever the rules say, including a nested repository's.
"""
function walk_disagreements(repo::AbstractString)
    matcher = IgnoreMatcher(repo)
    surviving = Set{String}()
    walkfiltered(matcher, repo) do dir, dirs, files
        prefix = relpath(dir, repo)
        prefix = prefix == "." ? "" : replace(prefix, '\\' => '/')
        for name in Iterators.flatten((dirs, files))
            push!(surviving, isempty(prefix) ? name : "$(prefix)/$(name)")
        end
        return true
    end
    paths = tree_paths(repo)
    theirs = ignored_paths(repo, first.(paths))
    report = String[]
    for (rel, is_dir) in paths
        expected = !(rel in theirs) && !(".git" in split(rel, '/'))
        expected == (rel in surviving) && continue
        push!(
            report, string(
                rel, is_dir ? "/" : "",
                rel in surviving ? ": walked, git calls it ignored" :
                    ": pruned, git calls it visible"
            )
        )
    end
    return report
end

"""
    sweep(patterns, build; into=".gitignore", alongside="") -> Vector{String}

Run one fixture tree against many patterns, rewriting the ignore file named by
`into` between them. `alongside` is written ahead of each swept pattern, and into
the root `.gitignore` as well when `into` names some other file, so that a swept
negation has something to negate. One repository and one `git`
invocation per pattern is what makes a few hundred patterns affordable; a fresh
matcher per pattern is required, since a matcher caches the rules it has read.
"""
function sweep(
        patterns, build; into::AbstractString = ".gitignore",
        alongside::AbstractString = ""
    )
    return withrepo() do repo
        build(repo)
        target = joinpath(repo, split(into, '/')...)
        mkpath(dirname(target))
        if into != ".gitignore"
            write(joinpath(repo, ".gitignore"), alongside)
        end
        report = String[]
        for pattern in patterns
            write(target, alongside * pattern * "\n")
            for line in disagreements(repo)
                push!(report, string(repr(pattern), " in ", into, " -> ", line))
            end
        end
        return report
    end
end

end # module GitOracle
