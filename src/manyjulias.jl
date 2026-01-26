module manyjulias

using Scratch, TOML, DataStructures, LazyArtifacts, JSON3, Random, Preferences, PrecompileTools, LibGit2
using elfshaker_jll, crun_jll

include("utils.jl")
include("libgit2.jl")
include("julia.jl")
include("elfshaker.jl")
include("sandbox.jl")
include("precompile.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")

    global data_dir = if @has_preference("data_dir")
        @load_preference("data_dir")
    else
        @get_scratch!("data")
    end

    global sandbox_dir = mktempdir()
end

function set_data_dir(dir::String)
    @set_preferences!("data_dir" => abspath(expanduser(dir)))
    global data_dir = dir
end

end # module manyjulias
