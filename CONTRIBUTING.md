# Contributing

The code is [Runic](https://github.com/fredrikekre/Runic.jl) formatted and CI
enforces it. Install the hook once in a fresh clone:

```
cp scripts/pre-commit-runic .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

The test suite needs a `git` binary for the differential comparison. Without one
it skips that suite and says so, and a run that skipped it proves nothing about
fidelity.