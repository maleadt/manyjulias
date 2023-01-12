function elfshaker_cmd(args; datadir, workdir=nothing)
    if workdir === nothing
        `$(elfshaker()) --data-dir $datadir $args`
    else
        setenv(`$(elfshaker()) --data-dir $datadir $args`; dir=workdir)
    end
end


## wrappers

function list(; datadir)
    loose = String[]
    packed = Dict{String,Vector{String}}()
    for line in eachline(elfshaker_cmd(`list`; datadir))
        m = match(r"^loose/(.+):\1$", line)
        if m !== nothing
            commit = m.captures[1]
            push!(loose, commit)
            continue
        end

        m = match(r"^(.+):(.+)$", line)
        if m !== nothing
            pack = m.captures[1]
            commit = m.captures[2]
            push!(get!(packed, pack, String[]), commit)
            continue
        end

        @error "Unexpected list output" line
    end

    return (; loose, packed)
end

function store!(commit, dir; datadir)
    prepare(dir)
    run(elfshaker_cmd(`store $commit`; datadir, workdir=dir))
    rm(dir; recursive=true)
end

function extract!(commit, dir)
    run(elfshaker_cmd(`extract --reset $commit`; datadir, workdir=dir))
    unprepare(dir)
    return dir
end
extract(commit; datadir) = extract!(commit, mktempdir(workdir); datadir)

# remove all loose packs
function rm_loose(; datadir)
    rm(joinpath(datadir, "loose"); recursive=true, force=true)
    rm(joinpath(datadir, "packs", "loose"); recursive=true, force=true)
end

function pack(name; datadir)
    run(elfshaker_cmd(`pack $name`; datadir))
end


## extensions

# prepare a built Julia directory for packing, recording metadata that elfshaker loses.
function prepare(dir)
    # elfshaker doesn't store some properties that we care about, such as file modes
    # and symbolic links. we'll package those up in a metadata file

    modes = OrderedDict()
    links = OrderedDict()
    function scan_dir(subdir)
        for entry in readdir(joinpath(dir, subdir))
            relative_path = joinpath(subdir, entry)
            absolute_path = joinpath(dir, relative_path)
            modes[relative_path] = "0o$(string(stat(absolute_path).mode; base=8))"
            if islink(absolute_path)
                links[relative_path] = readlink(absolute_path)
            elseif isdir(absolute_path)
                scan_dir(relative_path)
            end
        end
    end
    scan_dir("./")

    metadata = OrderedDict(
        "modes" => modes,
        "links" => links,
    )

    metadata_file = joinpath(dir, "metadata.toml")
    @assert !isfile(metadata_file)
    open(metadata_file, "w") do io
        TOML.print(io, metadata)
    end
end

# apply metadata to reconstruct a build directory
function unprepare(dir)
    metadata_file = joinpath(dir, "metadata.toml")
    @assert isfile(metadata_file)

    metadata = TOML.parsefile(metadata_file)

    for (relative_path, dest) in metadata["links"]
        absolute_path = joinpath(dir, relative_path)
        if ispath(absolute_path)
            @assert islink(absolute_path) && readlink(absolute_path) == dest
        else
            symlink(dest, absolute_path)
        end
    end

    for (relative_path, mode) in metadata["modes"]
        absolute_path = joinpath(dir, relative_path)
        chmod(absolute_path, parse(Int, mode))
    end

    rm(metadata_file)
end
