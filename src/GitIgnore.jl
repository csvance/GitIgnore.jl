"""
    GitIgnore

Git-faithful `.gitignore` matching and a pruning directory walk, with no
dependencies outside the standard library.

Build an [`IgnoreMatcher`](@ref) for the top of a tree, ask [`isignored`](@ref)
about a path, and use [`walkfiltered`](@ref) to walk the tree with ignored
subtrees pruned rather than filtered out afterwards.

The verdicts are checked against the real `git` binary: the test suite compares
this package with `git check-ignore` over generated trees and fails on any
disagreement. `libgit2` is not used, because it disagrees with git in at least
two ways this package gets right; the README has the detail.
"""
module GitIgnore

export IgnoreMatcher, isignored, walkfiltered, ignoreroot

include("patterns.jl")
include("matcher.jl")
include("walk.jl")

end # module GitIgnore
