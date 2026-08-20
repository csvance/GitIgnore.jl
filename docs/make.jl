using Documenter
using DocumenterCodeBlocks
using DocumenterLandingPage
using GitIgnore

makedocs(
    sitename = "GitIgnore.jl",
    # The docstring examples name paths that do not exist on a build machine,
    # so they are written as `julia` blocks rather than doctests. What the
    # package promises is checked by the test suite against the git binary,
    # which is a stronger check than a doctest could be.
    doctest = false,
    format = Documenter.HTML(
        edit_link = "main",
        canonical = "https://csvance.github.io/GitIgnore.jl/",
        inventory_version = "0.1.0",
    ),
    repo = Documenter.Remotes.GitHub("csvance", "GitIgnore.jl"),
    modules = [GitIgnore],
    # Only the exported names have to appear in the site. The internals carry
    # docstrings too, because the git behaviour they encode needs explaining to
    # whoever edits them, but they are not API and are not published.
    checkdocs = :exports,
    plugins = [
        LandingPage(),
        CodeBlocks(),
    ],
    pages = [
        "Home" => "index.md",
        "Guide" => "guide.md",
        "Fidelity to git" => "fidelity.md",
        "Benchmarks" => "benchmarks.md",
        "Optimisation record" => "optimisation.md",
        "API Reference" => "api.md",
    ],
)

Documenter.deploydocs(
    repo = "github.com/csvance/GitIgnore.jl.git",
    push_preview = true,
    devbranch = "main",
)
