using Test
using GitIgnore

@testset "GitIgnore.jl" begin
    include("patterns.jl")
    include("matcher.jl")
    include("walk.jl")
    include("differential.jl")
end
