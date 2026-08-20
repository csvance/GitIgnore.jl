# How this package compares with asking the `git` binary, which is the
# alternative it exists to replace.
#
# Run from the package root:
#
#     julia --project=. bench/benchmark.jl            # sampled subprocess cost
#     julia --project=. bench/benchmark.jl --full     # one git process per path
#
# The tree is built under the system temporary directory on purpose. Building it
# on a network filesystem measures the filesystem, not the matcher.

using GitIgnore
using Printf
using Statistics

const FULL = "--full" in ARGS
const SAMPLE = 300

const GITENV = ["GIT_CONFIG_GLOBAL" => "/dev/null",
                "GIT_CONFIG_SYSTEM" => "/dev/null",
                "GIT_CONFIG_NOSYSTEM" => "1"]

function build_tree(root::AbstractString)
    write(joinpath(root, ".gitignore"),
          "build/\nnode_modules/\n*.log\n!keep.log\n*.o\n")
    for group in 1:40
        dir = joinpath(root, "src", "group$(group)")
        mkpath(dir)
        group == 1 && write(joinpath(dir, ".gitignore"), "generated/\n*.inc\n")
        for file in 1:30
            write(joinpath(dir, "unit$(file).jl"), "x")
        end
    end
    for area in ("test", "docs")
        mkpath(joinpath(root, area))
        write(joinpath(root, area, ".gitignore"), "*.tmp\n")
        for file in 1:150
            write(joinpath(root, area, "page$(file).md"), "x")
            write(joinpath(root, area, "page$(file).tmp"), "x")
        end
    end
    for stage in 1:100
        dir = joinpath(root, "build", "stage$(stage)")
        mkpath(dir)
        for file in 1:100
            write(joinpath(dir, "object$(file).o"), "x")
        end
    end
    for package in 1:200
        dir = joinpath(root, "node_modules", "pkg$(package)")
        mkpath(dir)
        for file in 1:10
            write(joinpath(dir, "index$(file).js"), "x")
        end
    end
    for file in 1:100
        write(joinpath(root, "scratch$(file).log"), "x")
    end
    write(joinpath(root, "keep.log"), "x")
    return root
end

# Every path in the tree, ignored ones included, the way a caller who had not
# pruned would have to enumerate them.
function all_paths(root::AbstractString)
    paths = String[]
    for (dir, dirs, files) in walkdir(root)
        rel = relpath(dir, root)
        rel == "." && (rel = "")
        startswith(rel, ".git") && continue
        for name in Iterators.flatten((dirs, files))
            push!(paths, isempty(rel) ? name : "$(rel)/$(name)")
        end
    end
    return paths
end

best(f, runs::Int = 3) = minimum(@elapsed(f()) for _ in 1:runs)

function walk_count(matcher, root)
    total = 0
    walkfiltered(matcher, root) do _dir, _dirs, files
        total += length(files)
        return true
    end
    return total
end

function main()
    mktempdir() do root
        print("building the fixture tree ... ")
        build_tree(root)
        run(setenv(`git init -q -b main $(root)`, GITENV))
        paths = all_paths(root)
        @printf("%d entries\n", length(paths))

        matcher = IgnoreMatcher(root)
        visible = walk_count(matcher, root)
        walk = best(() -> walk_count(IgnoreMatcher(root), root))
        plain = best(() -> sum(length(files) for (_d, _ds, files) in walkdir(root)))
        # One matcher, then a query per entry: the cost a caller pays when it
        # has its own list of paths and cannot use the pruning walk.
        queries = best() do
            fresh = IgnoreMatcher(root)
            count(path -> isignored(fresh, path, false), paths)
        end

        batched = best() do
            input = IOBuffer(join(paths, '\0') * '\0')
            cmd = ignorestatus(setenv(Cmd(`git check-ignore --no-index --stdin -z`;
                                          dir = root), GITENV))
            run(pipeline(cmd; stdin = input, stdout = devnull, stderr = devnull))
        end
        listing = best() do
            cmd = setenv(Cmd(`git ls-files -o -i --exclude-standard --directory`;
                             dir = root), GITENV)
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
        end

        sampled = FULL ? paths : paths[1:min(SAMPLE, length(paths))]
        per_path = @elapsed for path in sampled
            cmd = ignorestatus(setenv(Cmd(`git check-ignore --no-index -q -- $(path)`;
                                          dir = root), GITENV))
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
        end
        scaled = per_path / length(sampled) * length(paths)

        println()
        @printf("tree: %d entries, %d files visible after pruning\n", length(paths), visible)
        println()
        @printf("%-46s %10s %12s\n", "operation", "seconds", "vs pruned walk")
        @printf("%-46s %10.4f %12s\n", "walkfiltered, whole tree pruned", walk, "1.0x")
        @printf("%-46s %10.4f %11.1fx\n", "walkdir, no ignore handling at all", plain, plain / walk)
        @printf("%-46s %10.4f %11.1fx\n", "isignored for every entry, no pruning", queries, queries / walk)
        @printf("%-46s %10.4f %11.1fx\n", "git check-ignore --stdin, one process", batched, batched / walk)
        @printf("%-46s %10.4f %11.1fx\n", "git ls-files -o -i --directory", listing, listing / walk)
        @printf("%-46s %10.4f %11.1fx\n",
                FULL ? "git check-ignore, one process per path" :
                       "git check-ignore per path, extrapolated",
                scaled, scaled / walk)
        @printf("\nper-path subprocess cost: %.3f ms (%d sampled)\n",
                per_path / length(sampled) * 1000, length(sampled))
        @printf("julia %s, %s\n", VERSION, strip(read(setenv(`git --version`, GITENV), String)))
    end
end

main()
