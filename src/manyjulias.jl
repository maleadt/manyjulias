module manyjulias

using Scratch, Git, TOML, DataStructures, ProgressMeter, Sandbox, LazyArtifacts
using elfshaker_jll

include("utils.jl")
include("julia.jl")
include("elfshaker.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")

    global datadir = @get_scratch!("data")
    global elfshaker_dir = joinpath(datadir, "elfshaker")
    mkpath(elfshaker_dir)
end

end # module manyjulias
