# GitIgnore.jl

[![Docs-dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://csvance.github.io/GitIgnore.jl/dev/)
[![Tests](https://img.shields.io/github/actions/workflow/status/csvance/GitIgnore.jl/CI.yml?branch=main&label=Tests)](https://github.com/csvance/GitIgnore.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Julia 1.11](https://img.shields.io/badge/Julia-1.11-9558b2)](https://julialang.org)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)

Git-faithful `.gitignore` matching and a pruning directory walk, with no
dependencies outside the Julia standard library.

An agent or a tool pointed at a repository should see the repository, not its
build output. `rg` solved that by honouring `.gitignore` and skipping `.git`.
This package is that behaviour on its own: compile the ignore rules under a
directory, ask whether a path is excluded, and walk a tree with the ignored
subtrees pruned rather than filtered out afterwards.

## Why this exists

Asking the `git` binary is too expensive to do per path: one `git check-ignore`
process costs about 1.3 ms, nearly all of it process spawn, so a 14,251 entry
tree costs 18.6 s where the pruning walk answers in 1.4 ms. Full parity with git
could not be established through the `LibGit2` bundled in Julia either, which
answered two reproduced cases differently from git 2.43. So the rules are
re-implemented here with no dependencies, and every verdict is checked against
the real binary by a differential test suite. The documentation has the numbers,
the two cases, and the limits of the guarantee.

## Usage

```julia
using GitIgnore

matcher = IgnoreMatcher("/path/to/repo")

isignored(matcher, "build")             # true when `build/` is a rule
isignored(matcher, "build/out.o")       # true as well, taken from the parent
isignored(matcher, "build", false)      # false: the rule wants a directory

sources = String[]
walkfiltered(matcher, "/path/to/repo") do dir, dirs, files
    append!(sources, joinpath(dir, name) for name in files if endswith(name, ".jl"))
    return true                         # `false` stops the walk
end
```


