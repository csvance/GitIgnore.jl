# Fidelity against real ignore files rather than generated ones.
#
# Point it at any number of checkouts and it compares this package with
# `git check-ignore` for every path in each, both per path and through the
# pruning walk:
#
#     julia --project=. bench/realworld.jl ~/src/one ~/src/two
#
# It reads only, and prints the first few disagreements per repository if there
# are any. This is not part of the test suite, because what it checks depends on
# which repositories happen to be on the machine.

using GitIgnore
using Printf

include(joinpath(@__DIR__, "..", "test", "gitoracle.jl"))

function main(repos)
    GitOracle.available() ||
        error("no usable git binary on PATH, so there is nothing to compare against")
    isempty(repos) &&
        error("usage: julia --project=. bench/realworld.jl <repo> [<repo>...]")
    total_paths = 0
    total_bad = 0
    for repo in repos
        if !isdir(repo)
            @warn "not a directory, skipping" repo
            continue
        end
        paths = GitOracle.tree_paths(repo)
        queries = GitOracle.disagreements(repo)
        walked = GitOracle.walk_disagreements(repo)
        total_paths += length(paths)
        total_bad += length(queries) + length(walked)
        @printf("%-30s %8d paths  %3d query  %3d walk\n",
                basename(rstrip(repo, '/')), length(paths), length(queries), length(walked))
        for line in Iterators.take(queries, 5)
            println("    query: ", line)
        end
        for line in Iterators.take(walked, 5)
            println("    walk:  ", line)
        end
    end
    @printf("\n%d paths over %d repositories, %d disagreements\n",
            total_paths, length(repos), total_bad)
    return total_bad
end

exit(main(ARGS) == 0 ? 0 : 1)
