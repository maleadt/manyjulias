#!/usr/bin/env julia

using Pkg
Pkg.activate(dirname(@__DIR__))

using manyjulias
using Git, DataStructures, ProgressMeter

const COMMITS_PER_PACK = 250
#const START_COMMIT = "ddf7ce9a595b0c84fbed1a42e8c987a9fdcddaac" # 1.6 branch point
const START_COMMIT = "7fe6b16f4056906c99cee1ca8bbed08e2c154c1a" # 1.10 branch point

function build_pack(pack_name, commits; workdir, ntasks)
    # check if we need to clean the slate
    unrelated_loose_commits = filter(manyjulias.list().loose) do commit
        !(commit in commits)
    end
    if !isempty(unrelated_loose_commits)
        @info "Unrelated loose commits detected; removing"
        manyjulias.rm_loose()
        # XXX: this may remove too much, but I don't think it's possible to remove select
        #      loose commits, as there's both the indices and the actual objects.
        #      elfshaker gc would help here (elfshaker/elfshaker#97)
    end
    loose_commits = manyjulias.list().loose

    # re-extract any packed commits we'll need again
    packs = manyjulias.list().packed
    packed_commits = isempty(packs) ? [] : union(values(packs)...)
    required_packed_commits = filter(commits) do commit
        commit in packed_commits && !(commit in loose_commits)
    end
    for commit in required_packed_commits
        dir = mktempdir(workdir)
        manyjulias.extract!(commit, dir)
        manyjulias.store!(commit, dir)
    end
    loose_commits = manyjulias.list().loose

    # the remaining commits need to be built
    remaining_commits = filter(commits) do commit
        !(commit in loose_commits)
    end
    @info "Need to build $(length(remaining_commits)) commits to complete pack $pack_name"
    elfshaker_lock = ReentrantLock()
    p = Progress(length(remaining_commits); desc="Building pack: ")
    asyncmap(remaining_commits; ntasks) do commit
        source_dir = mktempdir(workdir)
        install_dir = mktempdir(workdir)
        try
            manyjulias.julia_checkout!(commit, source_dir)
            echo = ntasks == 1
            manyjulias.build!(source_dir, install_dir; nproc=1, echo)
            exit(1)
            lock(elfshaker_lock) do
                manyjulias.store!(commit, install_dir)
            end
        catch err
            if !isa(err, manyjulias.BuildError)
                @error "Unexpected error while building $commit" exception=(err, catch_backtrace())
                rethrow(err)
            end
            err_lines = split(err.log, '\n')
            err_tail = join(err_lines[end-min(50,length(err_lines))+1:end], '\n')
            @error "Failed to build $commit:\n$err_tail"
        finally
            rm(source_dir; recursive=true, force=true)
            rm(install_dir; recursive=true, force=true)
            next!(p)
        end
    end

    # pack everything and clean up
    @info "Packing $pack_name"
    manyjulias.pack(manyjulias.safe_name("julia-$(pack_name)"))
    manyjulias.rm_loose()
end

function usage(error=nothing)
    error !== nothing && println("Error: $error\n")
    println("""
        Usage: $(basename(@__FILE__)) [options] <commit>

        Options:
            --help              Show this help message
            --workdir           Temporary storage location.
            --datadir           Where to store the generated packs.
            --threads=<n>       Use <n> threads for building (default: $(Sys.CPU_THREADS))""")
    exit(error === nothing ? 0 : 1)
end

function main(args; update=true)
    args, opts = manyjulias.parse_args(args)
    haskey(opts, "help") && usage()

    if haskey(opts, "datadir")
        manyjulias.datadir = abspath(expanduser(opts["datadir"]))
    end

    workdir = if haskey(opts, "workdir")
        abspath(expanduser(opts["workdir"]))
    else
        # NOTE: we use /var/tmp because that's less likely to be backed by tmpfs, as per FHS
        mktempdir("/var/tmp")
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
    available_commits = Set(union(manyjulias.list().loose,
                                  values(manyjulias.list().packed)...))
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
        build_pack(pack_name, commit_chunk; workdir, ntasks)
    end

    # XXX: remove loose if any loose commit isn't in the set we need

    return packs

    return
end

isinteractive() || main(ARGS)
