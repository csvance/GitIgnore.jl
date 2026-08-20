using Test
using GitIgnore

# The tree every test here works on.
function build_tree(dir::AbstractString)
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "build", "deep"))
    mkpath(joinpath(dir, "pkg", "local"))
    write(joinpath(dir, ".gitignore"), "build/\n*.log\n!keep.log\n*.tmp\n")
    write(joinpath(dir, "pkg", ".gitignore"), "!important.tmp\nlocal/\n")
    write(joinpath(dir, "top.jl"), "x")
    write(joinpath(dir, "keep.log"), "x")
    write(joinpath(dir, "src", "main.jl"), "x")
    write(joinpath(dir, "src", "app.log"), "x")
    write(joinpath(dir, "build", "out.jl"), "x")
    write(joinpath(dir, "build", "deep", "x.jl"), "x")
    write(joinpath(dir, "pkg", "important.tmp"), "x")
    write(joinpath(dir, "pkg", "scratch.tmp"), "x")
    write(joinpath(dir, "pkg", "local", "cache.jl"), "x")
    return dir
end

@testset "a path may be relative to the root or absolute" begin
    mktempdir() do dir
        build_tree(dir)
        matcher = IgnoreMatcher(dir)
        @test ignoreroot(matcher) == abspath(dir)
        @test isignored(matcher, "src/app.log")
        @test isignored(matcher, joinpath(dir, "src", "app.log"))
        @test isignored(matcher, "./src/app.log")
        @test !isignored(matcher, "src/main.jl")
        # The root itself is never ignored, however it is spelled.
        @test !isignored(matcher, "")
        @test !isignored(matcher, ".")
        @test !isignored(matcher, dir)
    end
end

@testset "a path outside the root is rejected rather than guessed at" begin
    mktempdir() do dir
        matcher = IgnoreMatcher(dir)
        @test_throws ArgumentError isignored(matcher, "../elsewhere.log")
        @test_throws ArgumentError isignored(matcher, "src/../../elsewhere.log")
        @test_throws ArgumentError isignored(matcher, joinpath(dirname(abspath(dir)), "x.log"))
    end
end

@testset "directory-ness comes from the filesystem unless the caller says" begin
    mktempdir() do dir
        write(joinpath(dir, ".gitignore"), "build/\n")
        mkpath(joinpath(dir, "build"))
        write(joinpath(dir, "buildfile"), "x")
        matcher = IgnoreMatcher(dir)
        @test isignored(matcher, "build")
        @test !isignored(matcher, "build", false)
        # A path that does not exist reads as a file, and can be asked about
        # either way.
        @test !isignored(matcher, "absent/build")
        @test isignored(matcher, "absent/build", true)
    end
end

@testset "an excluded directory cannot be re-included from below" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "build", "deep"))
        write(joinpath(dir, ".gitignore"), "build/\n")
        write(joinpath(dir, "build", ".gitignore"), "!keep.txt\n!deep/\n")
        write(joinpath(dir, "build", "keep.txt"), "x")
        write(joinpath(dir, "build", "deep", "x.jl"), "x")
        matcher = IgnoreMatcher(dir)
        # git tests each parent first, and so does this: the negation below the
        # excluded directory can never be reached.
        @test isignored(matcher, "build")
        @test isignored(matcher, "build/keep.txt")
        @test isignored(matcher, "build/deep")
        @test isignored(matcher, "build/deep/x.jl")
    end
end

@testset "a nested .gitignore governs its own subtree" begin
    mktempdir() do dir
        build_tree(dir)
        mkpath(joinpath(dir, "other"))
        write(joinpath(dir, "other", "important.tmp"), "x")
        matcher = IgnoreMatcher(dir)
        @test !isignored(matcher, "pkg/important.tmp")
        @test isignored(matcher, "pkg/scratch.tmp")
        @test isignored(matcher, "pkg/local")
        @test isignored(matcher, "pkg/local/cache.jl")
        # The re-inclusion is scoped to pkg/, so the same name elsewhere stays out.
        @test isignored(matcher, "other/important.tmp")
    end
end

@testset "explicit rules never touch the filesystem" begin
    matcher = IgnoreMatcher(joinpath("/", "nonexistent", "root"), ["" => "*.log\n"])
    @test isignored(matcher, "a.log", false)
    @test !isignored(matcher, "a.txt", false)
    # No rules at all, and still no filesystem access.
    empty_matcher = IgnoreMatcher("/nonexistent", [])
    @test !isignored(empty_matcher, "anything.log", false)
end

@testset ".git/info/exclude is honoured, and can be turned off" begin
    mktempdir() do dir
        mkpath(joinpath(dir, ".git", "info"))
        write(joinpath(dir, ".git", "info", "exclude"), "secret.txt\n")
        write(joinpath(dir, ".gitignore"), "*.log\n")
        write(joinpath(dir, "secret.txt"), "x")
        write(joinpath(dir, "public.txt"), "x")
        @test isignored(IgnoreMatcher(dir), "secret.txt")
        @test !isignored(IgnoreMatcher(dir), "public.txt")
        @test isignored(IgnoreMatcher(dir; excludes = false), "a.log", false)
        @test !isignored(IgnoreMatcher(dir; excludes = false), "secret.txt")
    end
end

@testset "a nested repository's excludes are honoured too" begin
    # Picking up a nested repository's `.gitignore` but not its excludes would
    # honour half its rules. This is a deliberate divergence from git run above
    # the nested repository, which reads only the outermost exclude file.
    mktempdir() do home
        repo = joinpath(home, "Git", "repo")
        mkpath(joinpath(repo, ".git", "info"))
        write(joinpath(repo, ".git", "info", "exclude"), "local-only.txt\n")
        write(joinpath(repo, "tracked.txt"), "x")
        write(joinpath(repo, "local-only.txt"), "x")
        matcher = IgnoreMatcher(home)
        @test isignored(matcher, "Git/repo/local-only.txt")
        @test !isignored(matcher, "Git/repo/tracked.txt")
    end
end

@testset "a .gitignore below the root governs from where it was found" begin
    # An agent started in a home directory walks into a repository, and that
    # repository's rules take effect from where they were found, apply all the
    # way down, anchor to the repository rather than to the root, and do not leak
    # to a sibling tree.
    mktempdir() do home
        repo = joinpath(home, "Git", "Project.jl")
        mkpath(joinpath(repo, "Sub", "src"))
        mkpath(joinpath(repo, "Sub", "build"))
        mkpath(joinpath(repo, "Other"))
        mkpath(joinpath(home, "Documents"))
        write(joinpath(repo, ".gitignore"), "*.jl.cov\n/Sub/Manifest.toml\nbuild/\n")
        matcher = IgnoreMatcher(home)
        @test !isignored(matcher, "Git/Project.jl/top.jl", false)
        # Unanchored, at the declaring directory and below it.
        @test isignored(matcher, "Git/Project.jl/top.jl.cov", false)
        @test isignored(matcher, "Git/Project.jl/Sub/src/deep.jl.cov", false)
        # Anchored to the repository, so the same basename elsewhere survives.
        @test isignored(matcher, "Git/Project.jl/Sub/Manifest.toml", false)
        @test !isignored(matcher, "Git/Project.jl/Other/Manifest.toml", false)
        @test isignored(matcher, "Git/Project.jl/Sub/build", true)
        # The repository's rules stop at the repository.
        @test !isignored(matcher, "Documents/notes.jl.cov", false)
    end
end

@testset "each directory's rules are read once" begin
    mktempdir() do dir
        write(joinpath(dir, ".gitignore"), "*.log\n")
        matcher = IgnoreMatcher(dir)
        @test isignored(matcher, "a.log", false)
        rm(joinpath(dir, ".gitignore"))
        # The cached rules stand: a matcher is a snapshot of what it has read,
        # which is what makes repeated queries cheap.
        @test isignored(matcher, "a.log", false)
        @test !isignored(IgnoreMatcher(dir), "a.log", false)
    end
end

@testset "one matcher can be shared across threads" begin
    mktempdir() do dir
        build_tree(dir)
        matcher = IgnoreMatcher(dir)
        paths = [
            "src/app.log", "src/main.jl", "pkg/important.tmp", "pkg/scratch.tmp",
            "build/deep/x.jl", "top.jl", "keep.log", "pkg/local/cache.jl",
        ]
        expected = [isignored(matcher, p, false) for p in paths]
        for _ in 1:8
            fresh = IgnoreMatcher(dir)
            answers = Vector{Bool}(undef, length(paths))
            Threads.@threads for index in eachindex(paths)
                answers[index] = isignored(fresh, paths[index], false)
            end
            @test answers == expected
        end
    end
end
