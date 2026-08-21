# Optimisation record

What was considered, what was measured, and what was rejected. The standing rule
is that a change trading git fidelity for speed or brevity is not worth it, so
most of this document is recorded rejections.

Evidence rules: a claim of a performance win needs a measurement on a tree built
on local disk, since `~/Git` is NFS mounted and timings there are an order of
magnitude slower and dominated by the filesystem. Anything unmeasured is labelled
speculation and is not acted on.

Two passes are recorded. The first was a timing review, on an 11,506 entry tree
with 1,416 directories and 32 ignore files at four depths and on the 14,251 entry
tree `bench/benchmark.jl` builds, and every measurement in it was reproduced here
before anything was applied. The second was an allocation pass with
`BenchmarkTools` and `Profile.Allocs` at `sample_rate = 1`, which attributes every
allocation to the line that made it, over a 12,048 entry tree; there the numbers
that matter are allocation counts, and wall-clock time did not move.

Every applied change was checked the same way: the differential suite green
(245 tests, including 34 comparisons against git 2.43), and `bench/realworld.jl`
over 24 real checkouts, 371,668 paths, with no disagreement in either the
per-path verdict or the pruning walk.

## Applied

### The walk no longer stats for ignore files it can already see

`walkfiltered` used to load a child directory's rules when it queued the child,
which is before it has listed it, so `load_dir_rules` had no choice but to stat
for `.gitignore` and for `.git/info/exclude` in every directory in the tree. On
the 11,506 entry tree that is 2,832 stat calls, at 3.6 us each on tmpfs and about
16 us each on NFS, to find 32 ignore files.

The load now happens when the directory is reached rather than when it is queued,
and `dir_entries` returns two flags with the listing it was building anyway:
whether `.git` and `.gitignore` are among the names. Neither file can exist unless
its name is in that listing, so two stat calls become two string comparisons in a
loop that already ran. `isignored` still probes, since it has no listing.

Measured, isolating rule loading as a fresh-matcher walk minus a warm-matcher
walk: 10.15 ms to 1.30 ms on the 11,506 entry tree, 0.42 ms to 0.15 ms on the
benchmark tree, 6.7 ms to 3.5 ms on an NFS tree. It scales with directory count,
so it is invisible on a shallow tree and dominant on a deep one, and it grows in
absolute terms on a network filesystem.

The one behavioural difference is that a directory that cannot be listed no
longer gets a cache entry, which no verdict depends on. The set of files read is
unchanged, and the guard in `load_ignore_patterns` still covers a `.gitignore`
that is a directory and a `.git` that is a worktree pointer file.

### Unanchored patterns are basename tests, and are matched as such

A pattern body with no `/` in it compiled to `^(?:.*/)?BODY$` and was matched
against the whole relative path. But no such body can match a `/`: the
translation only emits `[^/]*`, `[^/]`, `(?!/)[...]` and escaped literals, and a
body containing a literal or escaped `/` is anchored by definition. So the regex
matches a path exactly when `^BODY$` matches that path's last segment, and the
cheap shapes of that question need no regex at all. Patterns are now classified
at parse time into four kinds: the name equals a literal, the name ends with a
literal, a regex against the name, or a regex against the path. The one
unanchored body that can cross a separator is one made of nothing but stars,
which compiles to `.*`, so it stays a path test.

| | before | after | change |
| --- | --- | --- | --- |
| warm pruned walk, 11,506 entries | 14.09 ms | 9.31 ms | -34% |
| `isignored` over all 11,506 entries | 36.46 ms | 11.36 ms | -69% |
| `isignored` over all 14,251 entries | 8.50 ms | 4.17 ms | -51% |
| match cost alone, rules that never match | 7.30 ms | 1.21 ms | -83% |

Per operation: `occursin` with the unanchored regex against a six segment path is
139 ns, the anchored regex against the name is 42 ns, `endswith` is 4.6 ns, and
`==` is 4.3 ns. The end-to-end effect on `bench/benchmark.jl` is the pruned walk
going from 2.1 ms to 1.4 ms and the per-entry queries from 9.0 ms to 4.6 ms.

The correctness of this rests on the equivalence argument above, which is exactly
the kind of claim the differential suite exists to check, and it is checked: the
non-ASCII, whitespace, bracket and POSIX class fixtures all pass, as do the 780
swept patterns and the 371,576 real paths.

Two decisions inside this change are worth recording. The regex is still compiled
for the literal and suffix kinds even though nothing matches against it, which
costs 0.24 to 0.54 ms on a fresh walk: it keeps the faithful translation as the
single source of truth, and it keeps the option of cross-checking the fast path
against it. And prefix stripping for a nested rule set now returns a `SubString`
view rather than copying the path, which the old code did per rule set per entry.

### What was left out of that change

The review also proposed computing each rule set's view of the current directory
once per directory in the walk, rather than stripping per entry, and adding a
`needs_path` flag to `IgnoreRules` so the relative path is not built at all when
no rule needs it. Measured at about 2% of the walk, in exchange for a new field
and a second copy of the match loop. Not taken: the lazy form above gets the same
result for the common case, since a root rule set has an empty prefix and
stripping it is already free.

### Allocations

A separate pass with `BenchmarkTools` and `Profile.Allocs` at `sample_rate = 1`,
which attributes every allocation to the line that made it, over a 12,048 entry
tree on local disk. Wall-clock time did not move outside noise in any of this;
what follows is about allocations.

| | before | after |
| --- | --- | --- |
| `walkfiltered`, whole tree, warm matcher | 4,579 allocs, 0.33 MiB | 3,261 allocs, 0.25 MiB |
| `isignored`, absolute path | 58 allocs, 3,296 B, 4.59 us | 13 allocs, 560 B, 0.64 us |
| `isignored`, three segment relative path | 9 allocs, 336 B | 9 allocs, 336 B |
| `dir_entries`, 31 entry directory | 42 allocs, 3,248 B | 40 allocs, 2,960 B |

**An absolute path no longer goes through `relpath`.** Nearly all of the 58
allocations were one line: `relpath(abspath(path), root)`, which splits both
paths into components and compares them. A path under the root needs the root
sliced off the front instead, which is a `startswith` and a view. `relpath` is
kept for the case the slice cannot answer, a path that is not under the root at
all, where the `..` it produces is what turns the caller's mistake into the
`ArgumentError` they should get. Asking about an absolute path is the natural
thing to do with a path that came from `walkdir`, and it was the worst number in
the profile by an order of magnitude.

**The walk no longer builds a path per entry when nothing reads one.** A path is
read only by an anchored pattern or to decide whether a nested rule set applies,
and most ignore files contain neither, so `IgnoreRules` now records whether any
of its patterns looks at the path, and the walk checks once per directory whether
any rule in scope wants one. Where none does, the entry's own name stands in.
That was 1,843 of the walk's allocations on this tree, and 1,210 of them went
away; the rest are the two directories here that do have a nested rule set.

**`dir_entries` sizes its vector from the listing** rather than growing it an
entry at a time, since both listing functions return something with a length.

**The segment split moved into its own method.** Not a saving on its own: it is
what makes the first item safe, because a variable that is sometimes a `String`
and sometimes a view costs an allocation at every use of it.

## Tried, measured, reverted

Applied, measured and undone, which is neither of the two sections around it.
Recorded because the measurement is the only reason to prefer the code that is
there, and because three of the four were the same Julia mistake.

- **Segments as views instead of copies.** `Vector{SubString{String}}` avoids
  copying each segment, and cost more: the same allocation count, more bytes,
  because a view is three words where a string reference is one, and it made the
  accumulated relative path a union of two types, so `path_ignored` boxed its
  argument at every call. `isignored` went from 9 allocations to 12.
- **`sizehint!` on the segment vector**, from `count('/', text) + 1`. The count
  scan and the up-front buffer cost more than the growth they avoided:
  `root_segments` went from 5 allocations to 8.
- **An `occursin` guard before `replace` in `normalize_relpath`,** on the theory
  that `replace` allocates a new string even when it changes nothing. It does not:
  the line never appeared in the allocation profile, before or after. No benefit,
  so the guard went.
- **Looking the rule cache up before inserting,** to keep a view-typed key from
  being converted on a hit. Only useful with the views above, which are gone.

Still there and not worth touching: `copy` of the root's rules in `isignored` is
two allocations that a growable stack has to pay; the `dirs` and `files` vectors
grow in 138 allocations across the tree; and `isignored` could avoid materialising
segments at all by taking views of one normalised path, which is the shape the
walk already has, but it would need a second normalisation path beside
`split_segments` and that is where a fidelity bug would hide.

## Rejected

### Flattening, sharing or caching the per-directory rule stack

The premise did not survive contact with the code. `walkfiltered` only `vcat`s
when a child directory actually contributes rules, so on the 11,506 entry tree it
runs 31 times across 1,363 descended directories, not once per descent, and all
31 together cost 2.3 us, or 0.02% of the walk. The `copy` in the stack builders
is 35 ns, so 1,363 of them are 48 us. A prefix-keyed stack cache would add its
own invalidation and locking story for nothing measurable. The current shape, one
vector appended on the way down and shared by reference when the child adds
nothing, is already right.

### A global regex compilation cache

`Regex` construction is 3.5 us and a full translation is 8.7 us, so a seven
pattern file is 65 us and 32 ignore files are about 1.4 ms of a fresh walk. A
cache keyed by pattern body would help only a tree with many byte-identical
ignore files, at most about 1 ms there and nothing on a normal repository, in
exchange for process-global mutable state that has to be locked, never shrinks,
and holds data derived from untrusted input. Compilation is also once per matcher
rather than once per query, which is the wrong half of the workload. The applied
change above is the version of this idea that pays, because it removes matching
cost rather than construction cost.

### Removing the matcher's lock

The `ReentrantLock` costs 25 ns per rule lookup, which is 35 us per walk of the
11,506 entry tree, or 0.35%, and about 9% of a query-heavy `isignored` sweep. It
buys the documented and tested guarantee that one matcher can be shared across
threads, which an unlocked `Dict` read racing a write does not provide at any
Julia version. The lock-free alternative, an atomically swapped immutable
snapshot, makes reads free but turns cache population into a copy per directory,
which is quadratic in the number of cached prefixes and strictly worse for the
one-shot walk that is the main use.

### Removing the POSIX class and collating element machinery

`copy_posix_class` and `is_collating_element` are reachable only from a pattern
body containing `[`, so on a `.gitignore` of `*.log` and `build/` they never
execute at all, and they run at parse time in any case. The observation that
`[[:digit:]]` and `[=a=]` essentially never appear in a real `.gitignore` is
correct and is not the point: keeping them costs 30 lines that never run, and
dropping them costs correctness in exactly the way this package exists to avoid.
Without the first, `[[:digit:]].dat` becomes a class of the six characters in
`:digit` followed by a literal `]`, which silently matches the wrong files.
Without the second, `[=a=]` stops being inert and starts mistranslating. Both
hide a file the caller needed.

### Removing the `_readdirx` fallback

`HAS_READDIRX` is a compile-time constant, so the branch is folded and the
fallback costs nothing at runtime. It is three lines of insurance against a
non-public `Base` function disappearing, and since `dir_entries` took the choice
as a parameter it is no longer untested: the suite exercises both listing paths
and asserts they agree. It also turned out to be the only thing standing between
this package and running on Julia 1.10, where `_readdirx` does not exist.

### Shrinking the public API

Nothing in `IgnoreMatcher`, `isignored`, `walkfiltered`, `ignoreroot`, the
`excludes` keyword or the explicit-`sources` constructor is worth removing.
`excludes=false` is the only way to express "honour `.gitignore` only" and now
costs nothing when no `.git` is present. The explicit-`sources` constructor is how
pattern semantics are tested without a filesystem, is the documented spelling of
"no rules at all", and serves a caller whose rules are not on disk, for one
`Bool` field and one branch. `ignoreroot` is three lines and the only way to
recover the anchor. `walkfiltered`'s `skipped` cannot be reconstructed after the
fact, since pruning means the caller never sees what was dropped.

### Two micro-items

Reusing the `dirs` and `files` vectors across directories is about 1% of the walk
and would mean promising that the callback does not retain them, which the
docstring does not promise and a caller reasonably violates. Making
`root_segments` allocation-free is the largest remaining item inside `isignored`
at 310 ns of about 970 ns per query, but `isignored` needs the cumulative prefix
strings anyway to key the rule cache, so most of that is not recoverable; it was
not prototyped and stays speculation.

## One automaton per ignore file, instead of one regex per line

Rejected for now, and the reasoning is worth keeping because it is the most
substantial version of the idea the applied change above only approximates.

The matcher compiles each `.gitignore` line separately and, for each path, tests
every line of every applicable file in order, keeping the last match's verdict.
Cost is O(lines) tests per path per ignore file in scope, whatever each test
costs. The question raised was whether the lines of one ignore file could instead
be compiled into a single automaton, built once when the file is read and reused
for every path tested against it.

**This is expressible, and the scoping makes it clean.** Everything the
translator emits is regular: no backreferences, no capture-dependent behaviour,
and the one lookahead it emits, `(?!/)` in front of a bracket expression, is just
"this character is not a separator", which folds into the class. The semantics
needed are not "does any line match" but "which is the last matching line", which
is the standard lexer-generator construction: label each accepting state with the
highest-priority line that accepts there. `dir_only` needs the label to be a
pair, the best line for a file query and the best line for a directory query.
Compiling per ignore file rather than per rule stack also avoids the obvious
objection to a whole-stack automaton, which is that a deeper `.gitignore`
discovered during the walk would invalidate it.

**Measured, with a prototype.** A byte alphabet Thompson NFA, the four fixes it
needed, a gitignore-body-to-automaton translator and a lazily determinised DFA
were built and validated against the shipped matcher, then timed per match over
200 subjects. Two shapes of ignore file: `plain`, a mix of literal names, `*.ext`
suffixes and directory patterns, which is what real files mostly contain, and
`globby`, all `*x*N.log`, which is the shape that forces the shipped matcher to
run a regex per pattern.

| patterns | plain: shipped | plain: DFA | globby: shipped | globby: DFA |
| --- | --- | --- | --- | --- |
| 5 | 36 ns | 54 ns | 265 ns | 55 ns |
| 20 | 100 ns | 55 ns | 1,166 ns | 56 ns |
| 50 | 240 ns | 57 ns | 3,228 ns | 57 ns |
| 100 | 440 ns | 59 ns | 6,741 ns | 58 ns |
| 200 | 833 ns | 57 ns | 13,818 ns | 58 ns |
| 500 | 2,081 ns | 64 ns | 51,108 ns | 58 ns |

The DFA is flat, which is the entire point: a step is one table lookup per byte,
so a match costs the length of the subject and nothing per pattern. It crosses
over at about 10 plain patterns and is ahead at every size for glob-shaped ones,
reaching 32x at 500 plain patterns and 885x at 500 glob-shaped ones. State counts
stay small and do not explode: 22 to 132 DFA states across the plain sizes, and
172 for every globby size from 100 up.

**The NFA simulation on its own is a dead end.** Stepping a state set per byte
without determinising costs 791 ns at 5 plain patterns and 9,252 ns at 50, which
is worse than the shipped matcher everywhere and 20 to 100 times worse than the
DFA. Determinisation is not an optimisation of this idea, it is the idea.

**What it costs.** Cold, the automaton is roughly twice the parse: 1.7 ms against
994 us at 200 plain patterns, counting construction plus the first pass that
fills the transition tables. That is repaid after about 900 matches for plain
patterns and about 250 for glob-shaped ones, which any walk of a real repository
clears easily. Memory is the real cost: a dense 256 entry table of `Int32` per
state is 1 KiB, states materialise as subjects explore the automaton, and a run
whose subjects mostly match reached 354 states and 354 KiB for one 200 line
ignore file. An interval-keyed transition table would cut that, at the price of a
search per byte.

**And it still would not move the walk much.** Matching is not what a walk
spends its time on: `readdir` and `lstat` are, at roughly 1 us per entry against
36 ns of matching for a five line ignore file. The prize here is for a caller
making hundreds of thousands of `isignored` calls against a large ignore file,
not for `walkfiltered`.

**There is no off-the-shelf Julia package for it.** In the General registry,
`Automa.jl` is the only serious automata compiler, and it is a regex-to-Julia
*code* generator: its documented entry points end in `|> eval`, which is right
for patterns known when the code is written and wrong for patterns read out of a
`.gitignore` at runtime. Using it would mean an `eval` per ignore file, with the
world-age, latency and precompilation problems that brings, and it would cost the
zero-dependency claim, since it carries `PrecompileTools` and
`TranscodingStreams`. `RegularExpressions.jl` is a stale 0.1.0 helper for
assembling regex strings, not an engine, and there is no RE2, Hyperscan or
`regex-automata` equivalent. So this means writing the engine here, and the
hidden cost is Unicode: `[[:alpha:]]` and `café*` make the alphabet codepoints,
so transitions have to be interval based rather than a 256 entry byte table, or
the patterns have to be expanded into UTF-8 byte sequences.

**The cheaper version of the same idea was taken instead.** The shape buckets
described above are what `globset` does for ripgrep, and they are now applied: a
literal name is a `==`, a `*.ext` pattern is an `endswith`, and both resolve by
line index exactly as an automaton's accepting-state label would. Two further
steps short of an automaton remain available and are not taken, because nothing
measured justifies them yet: a capture-free union regex used purely as a reject
prefilter, which would skip the loop entirely for the majority of entries that
match nothing, and a priority-ordered alternation, which would answer in one
regex execution but needs capture bookkeeping to identify the branch.

Whatever is built, the sweep harness is what makes it safe: a fast path can be
compared against both git and the naive per-pattern implementation over generated
patterns, so a divergence shows up as a test failure rather than as a hidden file.
That is how the basename reduction was accepted.

**Verdict: real, and still not taken.** The measurement settles that the idea
works and how much it is worth: flat matching cost, a crossover at about ten
patterns, and orders of magnitude on glob-heavy files. What it does not settle is
whether this package should carry it. The prototype is around 500 lines of
automaton, translator and determiniser, all of which has to agree with git
exactly, in a package whose one claim is that its verdicts do. The differential
suite makes that checkable rather than hopeful, and the prototype already passes
it on the shapes benchmarked, so the door is open. It stays shut until a workload
turns up whose profile is dominated by matching against a large ignore file,
because for the walk the syscalls dominate and for a small ignore file the DFA is
slower than what is there now.
