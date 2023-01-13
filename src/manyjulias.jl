module manyjulias

using Scratch, Git, TOML, DataStructures, LazyArtifacts, JSON3, Random
using elfshaker_jll, crun_jll

include("utils.jl")
include("julia.jl")
include("elfshaker.jl")
include("sandbox.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")
    global data_dir = @get_scratch!("data")
end

function set_data_dir(dir=nothing; suffix=nothing)
    global data_dir
    if dir !== nothing
        data_dir = dir
    else
        data_dir = @get_scratch!("data")
    end
    if suffix !== nothing
        data_dir = joinpath(data_dir, suffix)
    end
    mkpath(data_dir)
end

end # module manyjulias
