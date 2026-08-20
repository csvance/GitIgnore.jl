# Optimisation and streamlining

What was considered, what was measured, and what was rejected. The standing rule
is that a change trading git fidelity for speed or brevity is not worth it, so
most of this document is recorded rejections.

Evidence rules: a claim of a performance win needs a measurement on a tree built
on local disk, since `~/Git` is NFS mounted and timings there are an order of
magnitude slower and dominated by the filesystem. Anything unmeasured is labelled
speculation and is not acted on. A review pass by a separate agent produced the
measurements below on two trees: an 11,506 entry tree with 1,416 directories and
32 ignore files at four depths, and the 14,251 entry tree `bench/benchmark.jl`
builds. Both were re-measured here before anything was applied.

Every applied change was checked the same way: the differential suite green
(220 tests at the time, 224 now, including 34 comparisons against git 2.43), and
`bench/realworld.jl` over 24 real checkouts, 371,576 paths, with no disagreement
in either the per-path verdict or the pruning walk.

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

**The cost it removes is linear in the number of lines, and the applied basename
change already took most of it.** Timing `isignored` over 2,000 three-segment
paths against an ignore file of N non-matching patterns, per path, after the
optimisations above:

| pattern shape | 6 | 50 | 200 | 500 |
| --- | --- | --- | --- | --- |
| `*.extN`, a suffix test | 0.64 us | 1.31 us | 4.26 us | 9.90 us |
| `fileN.txt`, a literal test | 0.43 us | 1.13 us | 3.27 us | 7.77 us |
| `*x*N.log`, needs a regex | 1.33 us | 10.60 us | 42.92 us | 133.21 us |
| `a/b/N.log`, anchored | 1.39 us | 10.11 us | 40.47 us | 123.02 us |

Before the basename change every row looked like the third one: 200 patterns cost
53 us per path whatever their shape. The linear factor is still there, but it now
costs 20 ns per pattern for the shapes real ignore files are mostly made of and
210 ns per pattern for the ones that need a regex. Across the 24 checkouts the
real-world check runs over, the largest `.gitignore` is 51 lines, the median is
under 20, and almost every line is a literal or a suffix, which puts a realistic
repository at about 1.3 us per entry tested. An automaton would still remove the
linear factor outright, and it would still be worth something on an ignore file of
a few hundred regex-shaped patterns, but the absolute numbers it competes against
are now an order of magnitude smaller than they were when this was first written.

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

**Verdict: deferred, and now further away than it was.** The shape buckets were
applied and are the cheap two thirds of this idea: a literal is a `==` and a
suffix is an `endswith`, and those two shapes cover most of what a real
`.gitignore` contains. What an automaton would add on top is removing the linear
factor for the regex-shaped remainder, and doing that means writing an
interval-based engine by hand, for a package whose one selling point is verified
fidelity. Revisit if a workload appears with hundreds of regex-shaped patterns in
one ignore file; until then the measurement does not justify the surface.
