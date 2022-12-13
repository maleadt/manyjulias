using Sandbox, Scratch, Git, LazyArtifacts, TOML, DataStructures
using elfshaker_jll

const COMMITS_PER_PACK = 250
const START_COMMIT = "ddf7ce9a595b0c84fbed1a42e8c987a9fdcddaac" # 1.6 branch point

# to get closer to CI-generated binaries, use a multiversioned build
const default_cpu_target = if Sys.ARCH == :x86_64
    "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
elseif Sys.ARCH == :i686
    "pentium4;sandybridge,-xsaveopt,clone_all"
elseif Sys.ARCH == :armv7l
    "armv7-a;armv7-a,neon;armv7-a,neon,vfp4"
elseif Sys.ARCH == :aarch64
    "generic;cortex-a57;thunderx2t99;carmel"
elseif Sys.ARCH == :powerpc64le
    "pwr8"
else
    @warn "Cannot determine JULIA_CPU_TARGET for unknown architecture $(Sys.ARCH)"
    ""
end

download_dir = @get_scratch!("downloads")
julia = joinpath(download_dir, "julia")

elfshaker_dir = @get_scratch!("elfshaker_data")

# we use a workdir in scratch, because /tmp might be size-limited tmpfs
workdir = @get_scratch!("workdir")
rm(workdir; recursive=true, force=true)
mkpath(workdir)

struct BuildError <: Exception
    log::String
end

function build(commit; nproc=Sys.CPU_THREADS)
    checkout = mktempdir(workdir)
    install_dir = mktempdir(workdir)

    # check-out the commit
    try
        run(`$(git()) clone --quiet $julia $checkout`)
        run(`$(git()) -C $checkout reset --quiet --hard $commit`)

        # pre-populate the srccache and save the downloaded files
        srccache = joinpath(download_dir, "srccache")
        mkpath(srccache)
        repo_srccache = joinpath(checkout, "deps", "srccache")
        cp(srccache, repo_srccache)
        run(ignorestatus(setenv(`make -C deps getall NO_GIT=1`; dir=checkout)),
            devnull, devnull, devnull)
        for file in readdir(repo_srccache)
            if !ispath(joinpath(srccache, file))
                cp(joinpath(repo_srccache, file), joinpath(srccache, file))
            end
        end

        # define a Make.user
        open("$checkout/Make.user", "w") do io
            println(io, "prefix=/install")
            #println(io, "JULIA_CPU_TARGET=$default_cpu_target")
            println(io, "JULIA_PRECOMPILE=0")

            # make generated code easier to delta-diff
            println(io, "CFLAGS=-ffunction-sections -fdata-sections")
            println(io, "CXXFLAGS=-ffunction-sections -fdata-sections")
        end

        # build and install Julia
        config = SandboxConfig(
            # ro
            Dict("/"        => artifact"package_linux"),
            # rw
            Dict("/source"  => checkout,
                 "/install" => install_dir),
            Dict("nproc"    => string(nproc));
            uid=1000, gid=1000
        )
        script = raw"""
            set -ue
            cd /source

            # Julia 1.6 requires a functional gfortran, but only for triple detection
            echo 'echo "GNU Fortran (GCC) 9.0.0"' > /usr/local/bin/gfortran
            chmod +x /usr/local/bin/gfortran

            # old releases somtimes contain bad checksums; ignore those
            sed -i 's/exit 2$/exit 0/g' deps/tools/jlchecksum

            make -j${nproc} install

            contrib/fixup-libgfortran.sh /install/lib/julia
            contrib/fixup-libstdc++.sh /install/lib /install/lib/julia
        """
        with_executor() do exe
            input = Pipe()
            output = Pipe()

            cmd = Sandbox.build_executor_command(exe, config, `/bin/bash -l`)
            cmd = pipeline(cmd; stdin=input, stdout=output, stderr=output)
            proc = run(cmd; wait=false)
            close(output.in)

            println(input, script)
            close(input)

            # collect output
            log_monitor = @async begin
                io = IOBuffer()
                while !eof(output)
                    line = readline(output; keep=true)
                    print(io, line)
                end
                return String(take!(io))
            end

            wait(proc)
            close(output)
            log = fetch(log_monitor)

            if !success(proc)
                throw(BuildError(log))
            end
        end

        # remove some useless stuff
        rm(joinpath(install_dir, "share", "doc"); recursive=true, force=true)
        rm(joinpath(install_dir, "share", "man"); recursive=true, force=true)

        return install_dir
    catch
        rm(install_dir; recursive=true)
        rethrow()
    finally
        rm(checkout; recursive=true)
    end
end

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

# XXX: prepare install dir; record symlink and permissions

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

# Julia version of contrib/commit-name.sh
function commit_name(commit)
    version = readchomp(`$(git()) -C $julia show $commit:VERSION`)
    endswith(version, "-DEV") || error("Only commits from the master branch are supported")

    branch_commit = let
        blame = readchomp(`$(git()) -C $julia blame -L ,1 -sl $commit -- VERSION`)
        split(blame)[1]
    end

    commits = let
        count = readchomp(`$(git()) -C $julia rev-list --count $commit "^$branch_commit"`)
        parse(Int, count)
    end

    return "$version.$(commits)"

    return (; version, commits)
end

function main(; update=false)
    global START_COMMIT

    # clone Julia
    if !ispath(joinpath(julia, "config"))
        run(`$(git()) clone --mirror --quiet https://github.com/JuliaLang/julia $julia`)
    elseif update
        run(`$(git()) -C $julia fetch --quiet --force origin`)
    end

    # list all commits we care about
    commits = let
        commits = String[]
        for line in eachline(`$(git()) -C $julia rev-list --reverse --first-parent $(START_COMMIT)\~..master`)
            # NOTE: --first-parent in order to exclude merged commits, because those don't
            #       have a unique version number (they can alias)
            push!(commits, line)
        end
        commits
    end

    # group into packs
    packs = OrderedDict()
    for commit_chunk in Iterators.partition(commits, COMMITS_PER_PACK)
        packs[commit_name(first(commit_chunk))] = commit_chunk
    end

    # find the latest commit we've already stored; we won't pack anything before that
    available_commits = Set(union(list().loose, values(list().packed)...))
    last_commit = nothing
    for commit in reverse(commits)
        if commit in available_commits
            last_commit = commit
            break
        end
    end
    if last_commit !== nothing
        @info "Last stored commit: $last_commit ($(commit_name(last_commit)))"
    end
    @show last_commit

    # create each pack
    for (pack_name, commit_chunk) in packs
        remaining_commits = if last_commit === nothing
            commit_chunk
        else
            last_commit_idx = findfirst(isequal(last_commit), commits)
            filter(commit_chunk) do commit
                commit_idx = findfirst(isequal(commit), commits)
                commit_idx > last_commit_idx
            end
        end
        if isempty(remaining_commits)
            @info "Skipping pack $pack_name"
            continue
        end
        @info "Creating pack $pack_name: $(length(remaining_commits)) commits to store"
        pack(pack_name, commit_chunk)
    end

    # XXX: remove loose if any loose commit isn't in the set we need

    return packs

    return
end

function pack(pack_name, commits; ntasks=Sys.CPU_THREADS)
    # check if we need to clean the slate
    unrelated_loose_commits = filter(list().loose) do commit
        !(commit in commits)
    end
    if !isempty(unrelated_loose_commits)
        @info "Unrelated loose commits detected; removing"
        rm_loose()
        # XXX: this may remove too much, but I don't think it's possible to remove select
        #      loose commits, as there's both the indices and the actual objects.
        #      elfshaker gc would help here (elfshaker/elfshaker#97)
    end
    loose_commits = list().loose

    # re-extract any packed commits we'll need again
    packed_commits = union(values(list().packed)...)
    required_packed_commits = filter(commits) do commit
        commit in packed_commits && !(commit in loose_commits)
    end
    for commit in required_packed_commits
        dir = extract(commit)
        store(commit; dir)
        rm(dir; recursive=true)
    end
    loose_commits = list().loose

    # the remaining commits need to be built
    remaining_commits = filter(commits) do commit
        !(commit in loose_commits)
    end
    @info "Need to build $(length(remaining_commits)) commits to complete pack $pack_name"
    elfshaker_lock = ReentrantLock()
    asyncmap(remaining_commits; ntasks) do commit
        try
            dir = build(commit; nproc=1)
            lock(elfshaker_lock) do
                store(commit; dir)
            end
            rm(dir; recursive=true)
        catch err
            isa(error, BuildError) || rethrow(err)
            err_lines = split(err.log, '\n')
            err_tail = join(err_lines[end-50:end], '\n')
            @error "Failed to build $commit:\n$err_tail"
        end
    end

    # pack everything and clean up
    @info "Packing $pack_name"
    pack(pack_name)
    rm_loose()
end
