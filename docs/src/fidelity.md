# Fidelity to git

The package's one distinguishing claim is that its verdicts match git's. This
page is what that claim rests on, and where it stops.

## Why this exists

Honouring `.gitignore` from Julia has two obvious routes. Neither one held up,
which is what the rest of this page is about.

### Asking the git binary is too expensive to do per path

One `git check-ignore` process costs about 1.3 ms, and nearly all of that is
process spawn rather than matching, so it does not improve with a warmer cache.
On a 14,251 entry tree that is 18.6 s, where the pruning walk answers the same
question in 1.4 ms.

Batching helps and is still the wrong shape: one `check-ignore --stdin` process
for every path costs 16 ms, but it cannot prune, so the caller has to enumerate
the whole tree, including the build directory it was trying to avoid, before it
can ask. The best subprocess design, one
`git ls-files -o -i --exclude-standard --directory`, comes within 2x of the
pruning walk on that tree and still needs a git binary, still needs a real
repository, and still pays a whole-repository scan per query. The full table and
its method are in [Benchmarks](benchmarks.md).

The correctness argument matters more than the speed. `git check-ignore` outside a
repository exits 128 with empty output, which reads exactly like "nothing here is
ignored": a tool built on it fails by showing the caller everything, quietly.

### Full parity with git could not be established through LibGit2

Julia ships `LibGit2`, which exposes `git_ignore_path_is_ignored`. It is the
obvious thing to reach for, and asked through a raw `ccall` on a fresh repository
handle with no traversal, libgit2 1.9 answered differently from git 2.43 in two
cases, so the difference is libgit2's behaviour rather than an artifact of how it
was called. Both are named regression tests here.

**A negation in a nested `.gitignore` did not override a shallower pattern.**
With `*.tmp` at the root and `!important.tmp` in `pkg/.gitignore`, git does not
ignore `pkg/important.tmp`. libgit2 ignored it.

**A directory-only pattern matched a symlink to a directory.** With `link/` in
`.gitignore`, where `link` is a symlink pointing at a directory, git does not
ignore `link`, because a symlink is a file however it resolves. libgit2 ignored
it.

Two divergences found is not a survey, and how much further they go is not
something we established. That is the difficulty rather than a footnote: both are
the kind of divergence that hides a file the caller needed, silently, and a
matcher whose verdicts cannot be checked against git is one you cannot trust to
hide only what git hides. Checking them is what this package does instead.

## How it is checked

`test/differential.jl` builds fixture trees in temporary repositories, asks this
package and `git check-ignore --no-index --stdin -z` about every path in each
one, and fails on any disagreement. Without `-v` that command prints exactly the
ignored paths, so its output is the answer rather than something to interpret,
and every call runs with the user's git configuration neutralised, since a global
`core.excludesFile` would otherwise make git ignore files this package never
reads.

Both answers are compared, because they are different code reaching the same
conclusion: the per-path verdict from [`isignored`](@ref), and the surviving set
the pruning walk reports.

Fourteen hand-built fixtures cover nested negation, negation below an excluded
directory, symlinks, anchoring and the `**` forms, the
ignore-everything-then-re-include idiom, repository-local excludes, whitespace
and CRLF and BOM handling, bracket expressions, POSIX classes, ranges a regex
engine would reject, non-ASCII names, a nested repository, and rules at five
depths. Around 780 further sweeps come from a table of 60 awkward patterns and a
deterministically generated set of pattern shapes, each rewriting one ignore file
and re-checking every path in a 30 entry tree, run through the root
`.gitignore`, a nested `.gitignore`, and `.git/info/exclude`: roughly 24,000 path
verdicts in all.

The suite skips itself with a message when no git binary is present, so the
package still tests on a machine without git. A run that skipped it proves
nothing about fidelity.

Generated fixtures are not the same thing as real ignore files, so
`bench/realworld.jl` runs the same comparison over any checkouts you point it at:

```
julia --project=. bench/realworld.jl ~/src/one ~/src/two
```

Over 24 checkouts on the author's machine, 371,576 paths, it found no
disagreement.

## What is deliberately not supported

- **Per-user and system-wide excludes are not read.** `core.excludesFile`,
  `$XDG_CONFIG_HOME/git/ignore` and the system gitignore need git configuration
  this package does not parse. Only `.gitignore` files and `.git/info/exclude`
  are consulted, and `excludes = false` narrows that to `.gitignore` alone.
- **Nothing above the root is consulted.** A `.gitignore` above the directory the
  matcher was built for governs a tree the caller did not ask about.
- **The index is not consulted.** These are pattern verdicts, matching
  `git check-ignore`, not `git status`. A tracked file whose name matches a
  pattern is reported as ignored, and `.git` is reported as ignored when a
  pattern actually matches it, which is what `check-ignore` does too.
- **Case is significant.** `core.ignorecase`, which git sets on case-insensitive
  filesystems, is not modelled. On Linux this is git's own behaviour; on macOS and
  Windows it is a real divergence.
- **`[=a=]` and `[.a.]` are inert.** Equivalence classes and collating elements
  are git syntax that PCRE does not implement, so a pattern containing one matches
  nothing rather than being mistranslated into a pattern that hides the wrong
  files. `[[:digit:]]` and the rest of the POSIX classes work.
- **Symlinks are never followed** by the walk, and a symlinked directory is
  reported as a file.
- **Nested repository excludes are honoured**, which is a deliberate divergence:
  git run above a nested repository reads only the outermost
  `.git/info/exclude`, while a matcher rooted above several repositories reads
  each one's. Honouring a nested repository's `.gitignore` but not its excludes
  would honour half its rules.

## The limits of the guarantee

The suite proves agreement with the git version it ran against, on the platform
it ran on, for the cases it covers. It does not prove anything about the
exclusions above, and the case-sensitivity gap is the one that would bite a macOS
or Windows user first.

Two translation limits are worth naming. `[=a=]` and `[.a.]` are inert, as above.
And a bracket range a regex engine rejects outright is emulated rather than
translated: git's `wildmatch` compares each member literally as it reads it and
applies a range only when it reaches the `-`, so `[c-a]` matches `c` and nothing
else. That behaviour is reproduced deliberately, and swept against git.
