module manyjulias

using Scratch, Git, TOML, DataStructures
using elfshaker_jll

include("utils.jl")
include("julia.jl")
include("elfshaker.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")
end

end # module manyjulias
