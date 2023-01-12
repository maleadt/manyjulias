const elfshaker_dir = @get_scratch!("elfshaker_data")

function elfshaker_cmd(args; dir=nothing)
    if dir === nothing
        `$(elfshaker()) --data-dir $elfshaker_dir $args`
    else
        setenv(`$(elfshaker()) --data-dir $elfshaker_dir $args`; dir)
    end
end

function store(commit; dir)
    prepare(dir)
    run(elfshaker_cmd(`store $commit`; dir))
end

function list()
    loose = String[]
    packed = Dict{String,Vector{String}}()
    for line in eachline(elfshaker_cmd(`list`))
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

# remove all loose packs
function rm_loose()
    rm(joinpath(elfshaker_dir, "loose"); recursive=true, force=true)
    rm(joinpath(elfshaker_dir, "packs", "loose"); recursive=true, force=true)
end

function pack(name)
    run(elfshaker_cmd(`pack $name`))
end

function extract(commit; dir=mktempdir(workdir))
    run(elfshaker_cmd(`extract --reset $commit`; dir))
    unprepare(dir)
    return dir
end
