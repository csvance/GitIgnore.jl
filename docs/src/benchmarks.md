# Benchmarks

The question this package exists to answer is whether a tool should ask the `git`
binary. `bench/benchmark.jl` measures that:

```
julia --project=. bench/benchmark.jl            # subprocess cost sampled
julia --project=. bench/benchmark.jl --full     # one git process per path
```

It builds a repository under the system temporary directory: 14,251 entries, of
which 1,505 files survive the ignore rules, with a 10,000 file `build/`
directory and a 2,000 file `node_modules/` both excluded, `.gitignore` files at
three depths, and scattered `*.log` files with one re-included by name. The tree
is built on local disk on purpose. Building it on a network filesystem measures
the filesystem rather than the matcher.

## Results

Julia 1.12.6, git 2.43.0, Linux, tree on local disk, best of three runs.

| operation | seconds | vs pruned walk |
| --- | --- | --- |
| `walkfiltered`, whole tree pruned | 0.0014 | 1.0x |
| `walkdir`, no ignore handling at all | 0.0086 | 6.0x |
| `isignored` for every entry, no pruning | 0.0046 | 3.3x |
| `git check-ignore --stdin`, one process | 0.0162 | 11.3x |
| `git ls-files -o -i --directory`, one process | 0.0027 | 1.9x |
| `git check-ignore`, one process per path | 18.63 | 13,027x |

Per-path subprocess cost: 1.307 ms, of which almost all is process spawn. An
earlier measurement of the same design on a 13,700 file tree put it at 2.12 ms
per path and 29 s for the tree; the difference is the machine and the disk, not
the shape of the result.

The in-process rows are what they are because of the two optimisations recorded
in the [optimisation record](optimisation.md). Before them the pruned walk cost 0.0021 s
and the per-entry queries 0.0090 s.

## Reading the table

**Honouring `.gitignore` is faster than ignoring it.** The pruned walk beats a
plain `walkdir` by 6x, because it never descends into the 12,700 entries the
rules exclude. Pruning at the directory level is what buys that, and it is also
git's semantics: a rule inside an excluded directory cannot re-include anything.

**Per-path subprocesses are not a design.** 18 s for one tree, and the cost is
spawn, not matching, so it does not improve with a warmer cache.

**Batching helps and is still the wrong shape.** One `check-ignore --stdin`
process for all 14,251 paths costs 16.2 ms, 11x the pruned walk, and it cannot
prune: the caller must enumerate the whole tree, including the build directory it
was trying to avoid, before it can ask.

**The best subprocess design is close, and still loses on everything else.** One
`git ls-files -o -i --exclude-standard --directory` costs 2.7 ms, within 2x of
the pruned walk on this tree. It also needs a git binary, needs a real
repository, pays a whole-repository scan per query, and fails silently: outside a
repository it exits 128 with empty output, which a caller reads as "nothing is
ignored". In process there is no binary to find, no repository required, and a
directory with no rules in it costs one string comparison per entry.
