# GitIgnore.jl

Git-faithful `.gitignore` matching and a pruning directory walk, with no
dependencies outside the Julia standard library.

An agent or a tool pointed at a repository should see the repository, not its
build output. `rg` solved that by honouring `.gitignore` and skipping `.git`.
This package is that behaviour on its own: compile the ignore rules under a
directory, ask whether a path is excluded, and walk a tree with the ignored
subtrees pruned rather than filtered out afterwards.

Its one distinguishing claim is fidelity. The verdicts are not read off the
`gitignore(5)` manual page; they are compared against the real `git` binary by a
differential test suite that walks generated fixture trees and fails on any
disagreement.

## Usage

```julia
using GitIgnore

matcher = IgnoreMatcher("/path/to/repo")

isignored(matcher, "build")             # true when `build/` is a rule
isignored(matcher, "build/out.o")       # true as well, taken from the parent
isignored(matcher, "build", false)      # false: the rule wants a directory
isignored(matcher, "src/main.jl")       # false

sources = String[]
result = walkfiltered(matcher, "/path/to/repo") do dir, dirs, files
    append!(sources, joinpath(dir, name) for name in files if endswith(name, ".jl"))
    return true                         # false stops the walk
end
result.completed                        # false when the callback stopped it
result.skipped                          # entries the rules removed
```

The root need not be a repository. Every `.gitignore` and `.git/info/exclude`
found on the way down applies to its own subtree, the way git applies it, so a
matcher rooted at a home directory still honours each repository it contains.

Rules that do not live on disk can be handed over directly, which is also how to
build a matcher that reads nothing at all:

```julia
inline = IgnoreMatcher(".", ["" => "*.log\n", "pkg" => "!keep.log\n"])
isignored(inline, "pkg/keep.log", false)      # false, the nested line wins

bare = IgnoreMatcher(".", [])                  # no rules; the walk still skips .git
```

Each directory's rules are read once, on first use, and cached in the matcher, so
repeated queries over one tree pay for a `.gitignore` at most once. Reading is
guarded by a lock, so one matcher can be shared across threads. A matcher is a
snapshot of what it has read: build a new one to pick up an edited `.gitignore`.

The exported surface is four names: `IgnoreMatcher`, `isignored`,
`walkfiltered`, and `ignoreroot`. Everything else is internal.

## Why not libgit2

Julia ships `LibGit2`, which exposes `git_ignore_path_is_ignored`. It is the
obvious thing to reach for, and it disagrees with git. Both of the following were
reproduced against libgit2 1.9 with a raw `ccall` on a fresh repository handle
and no traversal, so they are libgit2's behaviour rather than an artifact of how
it was called, and both are named regression tests here:

1. **A negation in a nested `.gitignore` does not override a shallower pattern.**
   With `*.tmp` at the root and `!important.tmp` in `pkg/.gitignore`, git 2.43
   does not ignore `pkg/important.tmp`. libgit2 ignores it.
2. **A `dir_only` pattern matches a symlink to a directory.** With `link/` in
   `.gitignore`, where `link` is a symlink pointing at a directory, git does not
   ignore `link`, because a symlink is a file however it resolves. libgit2
   ignores it.

Both are the kind of divergence that hides a file the caller needed, silently.

## Why not shell out to git

Because it does not scale, and because it fails quietly. On a 14,251 entry tree
on local disk, one `git check-ignore` process per path costs 19.0 s against
9.0 ms for the same queries in process, and the pruning walk answers the same
question in 2.1 ms. Batching every path through one `check-ignore --stdin`
process is affordable but cannot prune, so it pays for the whole tree whatever
the caller wanted. The full table and its method are in
[BENCHMARKS.md](BENCHMARKS.md).

The correctness argument matters more than the speed. `git check-ignore` needs a
git binary and a real repository, and outside one it exits 128 with empty output,
which reads exactly like "nothing here is ignored".

## What this package deliberately does not do

- **Per-user and system-wide excludes are not read.** `core.excludesFile`,
  `$XDG_CONFIG_HOME/git/ignore` and the system gitignore need git configuration
  this package does not parse. Only `.gitignore` files and `.git/info/exclude`
  are consulted, and `excludes=false` narrows that to `.gitignore` alone.
- **Nothing above the root is consulted.** A `.gitignore` above the directory the
  matcher was built for governs a tree the caller did not ask about.
- **The index is not consulted.** These are pattern verdicts, matching
  `git check-ignore`, not `git status`. A tracked file whose name matches a
  pattern is reported as ignored, and `.git` is reported as ignored when a
  pattern actually matches it, which is what `check-ignore` does too.
- **Case is significant.** `core.ignorecase`, which git sets on
  case-insensitive filesystems, is not modelled. On Linux this is git's own
  behaviour; on macOS and Windows it is a real divergence.
- **`[=a=]` and `[.a.]` are inert.** Equivalence classes and collating elements
  are git syntax that PCRE does not implement, so a pattern containing one
  matches nothing rather than being mistranslated into a pattern that hides the
  wrong files. `[[:digit:]]` and the rest of the POSIX classes work.
- **Symlinks are never followed** by the walk, and a symlinked directory is
  reported as a file. This is git's view and `walkdir`'s default.
- **Nested repository excludes are honoured**, which is a deliberate divergence:
  git run above a nested repository reads only the outermost
  `.git/info/exclude`, while a matcher rooted above several repositories reads
  each one's. Honouring a nested repository's `.gitignore` but not its excludes
  would honour half its rules.

## The fidelity guarantee, and its limits

`test/differential.jl` builds fixture trees in temporary repositories, asks this
package and `git check-ignore --no-index --stdin -z` about every path in each
one, and fails on any disagreement. Both answers are checked: the per-path
verdict from `isignored`, and the surviving set the pruning walk reports, which
is different code reaching the same conclusion.

Fourteen hand-built fixtures cover nested negation, negation below an excluded
directory, symlinks, anchoring and the `**` forms, the
ignore-everything-then-re-include idiom, repository-local excludes, whitespace
and CRLF and BOM handling, bracket expressions, POSIX classes, ranges a regex
engine would reject, non-ASCII names, a nested repository, and rules at five
depths. Around 780 further sweeps come from a table of 60 awkward patterns and a
deterministically generated set of pattern shapes, each rewriting one ignore file
and re-checking every path in a 30 entry tree, run through the root
`.gitignore`, a nested `.gitignore`, and `.git/info/exclude`: roughly 24,000
path verdicts in all.

The suite skips itself with a message when no git binary is present, so the
package still tests on a machine without git. A run that skipped it proves
nothing about fidelity.

What the guarantee does not cover: the exclusions listed above, git versions
other than the one the suite happened to run against, and platforms other than
the one it ran on. Two known translation limits are that `[=a=]` and `[.a.]`
are inert, and that a bracket range a regex engine rejects outright is emulated
rather than translated, matching git's own result for the reversed ranges the
suite checks.

## License

MIT. See [LICENSE](LICENSE).
