#!/usr/bin/env julia

using Pkg
Pkg.activate(dirname(@__DIR__))

using manyjulias
using ProgressMeter, Sandbox, Scratch, LazyArtifacts, Git, DataStructures

const COMMITS_PER_PACK = 250
#const START_COMMIT = "ddf7ce9a595b0c84fbed1a42e8c987a9fdcddaac" # 1.6 branch point
const START_COMMIT = "7fe6b16f4056906c99cee1ca8bbed08e2c154c1a" # 1.10 branch point

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

struct BuildError <: Exception
    log::String
end

const internet_lock = ReentrantLock()

# build a Julia commit and return the path to the install directory.
# consumes the source directory.
function build!(source_dir, install_dir; nproc=Sys.CPU_THREADS)
    # check-out the commit
    try
        # define a Make.user
        open("$source_dir/Make.user", "w") do io
            println(io, "prefix=/install")
            println(io, "JULIA_CPU_TARGET=$default_cpu_target")

            # make generated code easier to delta-diff
            println(io, "CFLAGS=-ffunction-sections -fdata-sections")
            println(io, "CXXFLAGS=-ffunction-sections -fdata-sections")
        end

        # build and install Julia
        rootfs = lock(internet_lock) do
            artifact"package_linux"
        end
        config = SandboxConfig(
            # ro
            Dict("/"        => rootfs),
            # rw
            Dict("/source"  => source_dir,
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
        rm(source_dir; recursive=true)
    end
end

function pack(pack_name, commits; workdir, datadir, ntasks)
    # check if we need to clean the slate
    unrelated_loose_commits = filter(manyjulias.list(; datadir).loose) do commit
        !(commit in commits)
    end
    if !isempty(unrelated_loose_commits)
        @info "Unrelated loose commits detected; removing"
        manyjulias.rm_loose(; datadir)
        # XXX: this may remove too much, but I don't think it's possible to remove select
        #      loose commits, as there's both the indices and the actual objects.
        #      elfshaker gc would help here (elfshaker/elfshaker#97)
    end
    loose_commits = manyjulias.list(; datadir).loose

    # re-extract any packed commits we'll need again
    packs = manyjulias.list(; datadir).packed
    packed_commits = isempty(packs) ? [] : union(values(packs)...)
    required_packed_commits = filter(commits) do commit
        commit in packed_commits && !(commit in loose_commits)
    end
    for commit in required_packed_commits
        dir = manyjulias.extract(commit; datadir)
        manyjulias.store!(commit, dir; datadir)
    end
    loose_commits = manyjulias.list(; datadir).loose

    # the remaining commits need to be built
    remaining_commits = filter(commits) do commit
        !(commit in loose_commits)
    end
    @info "Need to build $(length(remaining_commits)) commits to complete pack $pack_name"
    elfshaker_lock = ReentrantLock()
    p = Progress(length(remaining_commits); desc="Building pack: ")
    asyncmap(remaining_commits; ntasks) do commit
        try
            source_dir = mktempdir(workdir)
            manyjulias.julia_checkout!(commit, source_dir)
            try
                lock(internet_lock) do
                    manyjulias.populate_srccache!(source_dir)
                end
            catch err
                @error "Failed to populate srccache for $commit" exception=(err, catch_backtrace())
            end
            install_dir = mktempdir(workdir)
            build!(source_dir, install_dir; nproc=1)
            lock(elfshaker_lock) do
                manyjulias.store!(commit, install_dir; datadir)
            end
        catch err
            if !isa(err, BuildError)
                @error "Unexpected error while building $commit" exception=(err, catch_backtrace())
                rethrow(err)
            end
            err_lines = split(err.log, '\n')
            err_tail = join(err_lines[end-min(50,length(err_lines))+1:end], '\n')
            @error "Failed to build $commit:\n$err_tail"
        finally
            next!(p)
        end
    end

    # pack everything and clean up
    @info "Packing $pack_name"
    manyjulias.pack(manyjulias.safe_name("julia-$(pack_name)"); datadir)
    manyjulias.rm_loose(; datadir)
end

function usage(error=nothing)
    error !== nothing && println("Error: $error\n")
    println("""
        Usage: $(basename(@__FILE__)) [options] <commit>

        Options:
            --help              Show this help message
            --workdir           Temporary storage location.
            --datadir           Where to store the generated packs.
            --threads <n>       Use <n> threads for building (default: $(Sys.CPU_THREADS))""")
    exit(error === nothing ? 0 : 1)
end

function main(args; update=true)
    args, opts = manyjulias.parse_args(args)
    haskey(opts, "help") && usage()
    haskey(opts, "datadir") || usage("Missing --datadir")

    datadir = abspath(expanduser(opts["datadir"]))
    mkpath(datadir)

    workdir = if haskey(opts, "workdir")
        abspath(expanduser(opts["workdir"]))
    else
        mktempdir()
    end
    mkpath(workdir)

    ntasks = if haskey(opts, "threads")
        parse(Int, opts["threads"])
    else
        Sys.CPU_THREADS
    end

    julia = manyjulias.julia_repo()

    global START_COMMIT

    # list all commits we care about
    @info "Listing commits..."
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
    @info "Structuring in packs..."
    packs = OrderedDict()
    for commit_chunk in Iterators.partition(commits, COMMITS_PER_PACK)
        packs[manyjulias.commit_name(julia, first(commit_chunk))] = commit_chunk
    end

    # find the latest commit we've already stored; we won't pack anything before that
    available_commits = Set(union(manyjulias.list(; datadir).loose,
                                  values(manyjulias.list(; datadir).packed)...))
    last_commit = nothing
    for commit in reverse(commits)
        if commit in available_commits
            last_commit = commit
            break
        end
    end
    if last_commit !== nothing
        @info "Last stored commit: $last_commit ($(manyjulias.commit_name(julia, last_commit)))"
    end

    # create each pack
    @info "Creating $(length(packs)) packs..."
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
        pack(pack_name, commit_chunk; workdir, datadir, ntasks)
    end

    # XXX: remove loose if any loose commit isn't in the set we need

    return packs

    return
end

isinteractive() || main(ARGS)
