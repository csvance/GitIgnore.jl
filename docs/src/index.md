```@raw html
---
layout: home

hero:
  name: GitIgnore.jl
  text: Git-faithful .gitignore matching
  tagline: A dependency-free matcher and a pruning directory walk, with every verdict checked against the real git binary rather than against the manual page.
  actions:
    - theme: brand
      text: Get started
      link: /guide/
    - theme: alt
      text: Fidelity to git
      link: /fidelity/
    - theme: alt
      text: View on GitHub
      link: https://github.com/csvance/GitIgnore.jl

features:
  - icon: 🔍
    title: Checked against git
    details: The test suite asks this package and git check-ignore about every path in generated fixture trees and fails on any disagreement, per path and through the walk.
  - icon: ✂️
    title: Pruning walk
    details: An ignored directory is never descended into, which is git's own semantics and makes honouring .gitignore six times faster than a walk that ignores it.
  - icon: 🪶
    title: Zero dependencies
    details: The standard library and nothing else, so it costs a registered package nothing to depend on.
  - icon: 🧭
    title: Nested rules
    details: Every .gitignore and .git/info/exclude below the root governs its own subtree, so a matcher rooted at a home directory still honours each repository in it.
  - icon: 🚫
    title: Not libgit2
    details: Full parity with git could not be established through the LibGit2 bundled in Julia, which answers two reproduced cases differently. Both are named regression tests here.
  - icon: ⚡
    title: Not a subprocess
    details: One git process per path costs 18.6 s on a 14,251 entry tree, where the pruning walk answers in 1.4 ms.
---
```

## What it is

An agent or a tool pointed at a repository should see the repository, not its
build output. `rg` solved that by honouring `.gitignore` and skipping `.git`.
This package is that behaviour on its own: compile the ignore rules under a
directory, ask whether a path is excluded, and walk a tree with the ignored
subtrees pruned rather than filtered out afterwards.

```julia
using GitIgnore

matcher = IgnoreMatcher("/path/to/repo")
isignored(matcher, "build/out.o")        # true, taken from the parent directory

walkfiltered(matcher, "/path/to/repo") do dir, dirs, files
    @info "surviving" dir files
    return true
end
```

The root need not be a repository. One matcher covers a whole directory of
checkouts, and each repository's rules govern its own subtree, which is what git
does:

```julia
checkouts = IgnoreMatcher("/home/me/src")

isignored(checkouts, "app/build/out.o")   # true, from app/.gitignore
isignored(checkouts, "lib/scratch.txt")   # true, from lib/.git/info/exclude
isignored(checkouts, "notes/debug.log")   # false, notes is not a repository
```

There is no separate interface for that case; see
[Nested repositories](guide.md#Nested-repositories) for the whole worked example.

Start with the [Guide](guide.md) for the whole API, or with
[Fidelity to git](fidelity.md), which opens with why this package exists at all:
asking the `git` binary costs a process spawn per path, and full parity with git
could not be established through the `LibGit2` bundled in Julia. The same page
covers how the verdicts are verified and what is deliberately not supported.
