using Test
using GitIgnore

# Every surviving path the walk reports, relative to `start`, for comparison.
function walked(matcher::IgnoreMatcher, start::AbstractString; kwargs...)
    seen = String[]
    result = walkfiltered(matcher, start; kwargs...) do dir, dirs, files
        for name in Iterators.flatten((dirs, files))
            rel = relpath(joinpath(dir, name), start)
            push!(seen, replace(rel, '\\' => '/'))
        end
        return true
    end
    return sort!(seen), result
end

@testset "an ignored directory is never descended into" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "node_modules", "pkg"))
        write(joinpath(dir, ".gitignore"), "node_modules/\n")
        write(joinpath(dir, "node_modules", "pkg", "index.js"), "x")
        write(joinpath(dir, "keep.js"), "x")

        matcher = IgnoreMatcher(dir)
        visited = String[]
        result = walkfiltered(matcher, dir) do root, _dirs, _files
            push!(visited, root)
            return true
        end
        @test length(visited) == 1
        @test !any(v -> occursin("node_modules", v), visited)
        # The pruned directory is counted once, not once per file inside it.
        @test result.completed
        @test result.skipped == 1

        # A matcher with no rules walks the whole tree.
        everything, _ = walked(IgnoreMatcher(dir, []), dir)
        @test "node_modules/pkg/index.js" in everything
    end
end

@testset "walkfiltered stops when the callback says so" begin
    mktempdir() do dir
        for name in ("a", "b", "c")
            mkpath(joinpath(dir, name))
            write(joinpath(dir, name, "f.txt"), "x")
        end
        matcher = IgnoreMatcher(dir)
        seen = String[]
        result = walkfiltered(matcher, dir) do root, _dirs, _files
            push!(seen, basename(root))
            return length(seen) < 2
        end
        @test !result.completed
        @test length(seen) == 2
    end
end

@testset ".git is skipped whether or not a rule mentions it" begin
    mktempdir() do dir
        mkpath(joinpath(dir, ".git", "objects"))
        write(joinpath(dir, ".git", "objects", "blob"), "binaryish")
        write(joinpath(dir, "real.jl"), "x")

        paths, result = walked(IgnoreMatcher(dir), dir)
        @test paths == ["real.jl"]
        # Skipping `.git` hides nothing about the repository, so it is not counted.
        @test result.skipped == 0

        # And a caller who wants it can say so.
        with_git, _ = walked(IgnoreMatcher(dir), dir; skipgit = false)
        @test ".git/objects/blob" in with_git
    end
end

@testset "an unreadable directory does not fail the walk" begin
    mktempdir() do dir
        locked = joinpath(dir, "locked")
        mkpath(locked)
        write(joinpath(dir, "ok.txt"), "x")
        chmod(locked, 0o000)
        try
            paths, result = walked(IgnoreMatcher(dir), dir)
            # Probing the unreadable directory for a `.gitignore` must not throw
            # EACCES before the walk's own guard can run.
            @test "ok.txt" in paths
            @test "locked" in paths
            @test result.completed
        finally
            chmod(locked, 0o755)
        end
    end
end

@testset "a symlinked directory is reported as a file and not followed" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "real"))
        write(joinpath(dir, "real", "inner.jl"), "x")
        symlink(joinpath(dir, "real"), joinpath(dir, "link"))

        paths, _ = walked(IgnoreMatcher(dir, []), dir)
        @test "link" in paths
        @test "real/inner.jl" in paths
        @test !("link/inner.jl" in paths)

        files_seen = String[]
        walkfiltered(IgnoreMatcher(dir, []), dir) do _dir, _dirs, files
            append!(files_seen, files)
            return true
        end
        @test "link" in files_seen
    end
end

@testset "the walk may start below the root, and never prunes its start" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "build", "deep"))
        write(joinpath(dir, ".gitignore"), "build/\n*.log\n")
        write(joinpath(dir, "build", "out.jl"), "x")
        write(joinpath(dir, "build", "out.log"), "x")
        write(joinpath(dir, "build", "deep", "x.jl"), "x")

        matcher = IgnoreMatcher(dir)
        # A caller that names an ignored directory has asked for it, the same way
        # `rg dist/` searches `dist/`. The rules still apply inside it.
        paths, result = walked(matcher, joinpath(dir, "build"))
        @test paths == ["deep", "deep/x.jl", "out.jl"]
        @test result.skipped == 1
    end
end

@testset "a nested .gitignore is picked up on the way down" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "pkg", "local"))
        mkpath(joinpath(dir, "other"))
        write(joinpath(dir, ".gitignore"), "*.tmp\n")
        write(joinpath(dir, "pkg", ".gitignore"), "!important.tmp\nlocal/\n")
        write(joinpath(dir, "pkg", "important.tmp"), "x")
        write(joinpath(dir, "pkg", "scratch.tmp"), "x")
        write(joinpath(dir, "pkg", "local", "cache.jl"), "x")
        write(joinpath(dir, "other", "important.tmp"), "x")

        paths, _ = walked(IgnoreMatcher(dir), dir)
        @test paths == [".gitignore", "other", "pkg", "pkg/.gitignore", "pkg/important.tmp"]
    end
end

@testset "the walk and isignored agree on the same tree" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src", "deep"))
        mkpath(joinpath(dir, "build"))
        mkpath(joinpath(dir, "vendor", "lib"))
        write(joinpath(dir, ".gitignore"), "build/\n*.log\n!keep.log\nvendor\n")
        write(joinpath(dir, "src", ".gitignore"), "deep/\n")
        for path in ("top.jl", "keep.log", "a.log", "src/main.jl", "src/app.log",
                     "build/out.jl", "vendor/lib/x.jl", "src/deep/y.jl")
            write(joinpath(dir, split(path, '/')...), "x")
        end

        matcher = IgnoreMatcher(dir)
        surviving, _ = walked(matcher, dir)
        @test !any(path -> isignored(matcher, path), surviving)

        # Nothing the walk dropped was reachable without an ignored ancestor.
        dropped = String[]
        for (root, dirs, files) in walkdir(dir)
            for name in Iterators.flatten((dirs, files))
                rel = replace(relpath(joinpath(root, name), dir), '\\' => '/')
                startswith(rel, ".git/") && continue
                rel in surviving || push!(dropped, rel)
            end
        end
        @test !isempty(dropped)
        @test all(path -> isignored(matcher, path), dropped)
    end
end
