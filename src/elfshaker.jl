function elfshaker_cmd(db::String, args; dir=nothing)
    # we maintain multiple elfshaker databases, one for each Julia version.
    db_data_dir = joinpath(data_dir, db)
    mkpath(db_data_dir)

    if dir === nothing
        `$(elfshaker()) --data-dir $db_data_dir $args`
    else
        setenv(`$(elfshaker()) --data-dir $db_data_dir $args`; dir)
    end
end


## wrappers

elfshaker_lock = ReentrantLock()

function list(db::String)
    loose = String[]
    packed = Dict{String,Vector{String}}()

    lock(elfshaker_lock) do
        for line in eachline(elfshaker_cmd(db, `list`))
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
    end

    return (; loose, packed)
end

function store!(db::String, commit, dir)
    prepare(dir)
    lock(elfshaker_lock) do
        run(elfshaker_cmd(db, `store $commit`; dir))
    end
    rm(dir; recursive=true)
end

function extract!(db::String, commit, dir)
    lock(elfshaker_lock) do
        run(elfshaker_cmd(db, `extract --reset $commit`; dir))
    end
    unprepare(dir)
    return dir
end

# remove all loose packs
function rm_loose(db::String)
    lock(elfshaker_lock) do
        rm(joinpath(data_dir, db, "loose"); recursive=true, force=true)
        rm(joinpath(data_dir, db, "packs", "loose"); recursive=true, force=true)
    end
end

function pack(db::String, name)
    lock(elfshaker_lock) do
        run(elfshaker_cmd(db, `pack $name`))
    end
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

# version of extract! that does not mutate the data dir (e.g., for use on shared servers)
function extract_readonly!(db::String, commit, dir)
    # as elfshaker doesn't have an option to write loose directories outside of the data dir
    # we use a container with an overlay filesystem to avoid modifications.

    rootfs = lock(artifact_lock) do
        artifact"package_linux"
    end
    workdir = mktempdir()
    sandbox_cmd =
        sandbox(`/elfshaker/bin/elfshaker extract --data-dir /data_dir --reset $commit`;
                rootfs, workdir, uid=1000, gid=1000, cwd="/target_dir",
                mounts=Dict(
                    "/elfshaker:ro"     => elfshaker_jll.artifact_dir,
                    "/data_dir"         => joinpath(data_dir, db),
                    "/target_dir:rw"    => dir))
    try
        run(sandbox_cmd)
    finally
        if VERSION < v"1.9-"    # JuliaLang/julia#47650
            chmod_recursive(workdir, 0o777)
        end
        rm(workdir; recursive=true)
    end
    unprepare(dir)
    return dir
end

# we want the database to be usable by other users (via extract_readonly!)
function allow_shared_access!(db::String)
    db_data_dir = joinpath(data_dir, db)

    # make sure files in the database are accessible to other users
    function process(path)
        if isdir(path)
            chmod(path, 0o0755)
            foreach(process, readdir(path; join=true))
        elseif isfile(path)
            chmod(path, 0o644)
        end
    end
    process(db_data_dir)

    # get rid of the `trash` directory, which the other users' elfshaker will
    # want to access (and even with overlayfs, we get EPERM if it exists)
    rm(joinpath(db_data_dir, "trash"); recursive=true, force=true)

    return
end
