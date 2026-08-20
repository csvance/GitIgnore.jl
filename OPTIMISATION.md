# Optimisation and streamlining

What was considered, what was measured, and what was rejected. The standing rule
is that a change trading git fidelity for speed or brevity is not worth it, so
several entries here are recorded rejections rather than improvements.

Evidence rules: a claim of a performance win needs a measurement on a tree built
on local disk, since `~/Git` is NFS mounted and timings there are an order of
magnitude slower and dominated by the filesystem. Anything unmeasured is labelled
speculation and is not acted on.

## One automaton per ignore file, instead of one regex per line

The current matcher compiles each `.gitignore` line to its own `Regex` and, for
each path, runs every line's regex in order, keeping the last match's verdict.
Cost is O(lines) regex executions per path per ignore file in scope. The question
raised was whether the lines of one ignore file could instead be compiled into a
single automaton, built once when the file is read and reused for every path
tested against it.

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

**The cost it removes is linear in the number of lines, and measurable.** Timing
`isignored` over 2,000 three-segment paths against an ignore file of N
non-matching patterns:

| patterns | per path |
| --- | --- |
| 6 | 1.4 us |
| 20 | 4.6 us |
| 50 | 11.8 us |
| 100 | 23.9 us |
| 200 | 53.4 us |
| 500 | 194.7 us |

That is roughly 0.25 to 0.4 us per pattern per path, and it is the worst case in
the sense that matters: a pattern that does not match is scanned to the end, and
most patterns do not match most paths. On the benchmark tree, where only six
patterns are in force, a query costs 0.63 us and the whole pruned walk of 14,251
entries costs 2.1 ms, most of it `readdir` syscalls. Across the 24 checkouts the
real-world check runs over, the largest `.gitignore` is 51 lines and the median
is under 20, which puts a realistic repository at around 12 us per entry tested.
An earlier version of this document extrapolated 20 us per path at 200 patterns
from the six-pattern figure; the measurement above says 53 us, so the linear
factor is worth more than it looked.

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

**Cheaper versions of the same idea come first.** In ascending order of work:
a capture-free union regex used only as a reject prefilter, which skips the loop
entirely for the majority of entries that match nothing; shape buckets, where an
exact basename goes into a `Set`, a `*.ext` pattern into an extension
dictionary, and an anchored literal path into another `Set`, each storing its
line index so resolution is a max over three lookups, which is what `globset`
does for ripgrep and covers most real ignore lines in about sixty lines of code;
and a priority-ordered alternation, which answers in one regex execution but
needs capture bookkeeping to identify the branch. None of these is justified by
the measurements above, and all of them are safe to attempt later, because the
sweep harness can compare a fast path against both git and the naive
per-pattern implementation over generated patterns. A divergence shows up as a
test failure rather than as a hidden file.

**Verdict: the automaton is deferred, the shape buckets are the thing to do
first.** Writing an interval-based automaton engine by hand, for a package whose
one selling point is verified fidelity, is a large new surface for a subtle
divergence, and it should wait for a workload with ignore files of a few hundred
lines. The shape buckets get most of the same asymptotics for about sixty lines
of code that the sweep harness can verify, and at 12 us per entry tested on a
realistic 50 line ignore file they are worth having.
