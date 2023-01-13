#!/usr/bin/env julia

using Pkg
Pkg.activate(dirname(@__DIR__))

using manyjulias
using Git, DataStructures, ProgressMeter

const COMMITS_PER_PACK = 250

# determine the points where Julia versions branched
function julia_branch_commits()
    julia = manyjulias.julia_repo()

    commit = "master"
    branch_commits = Dict{VersionNumber,String}()
    while !haskey(branch_commits, v"1.6")
        commit = let
            blame = readchomp(`$(git()) -C $julia blame -L ,1 -sl $commit -- VERSION`)
            split(blame)[1]
        end

        version = VersionNumber(readchomp(`$(git()) -C $julia show $commit:VERSION`))

        version = Base.thisminor(version)
        @assert !haskey(branch_commits, version)
        branch_commits[version] = commit

        commit = "$(commit)~"
    end

    branch_commits
end

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
    p = Progress(length(remaining_commits); desc="Building pack: ")
    asyncmap(remaining_commits; ntasks) do commit
        source_dir = mktempdir(workdir)
        install_dir = mktempdir(workdir)
        try
            manyjulias.julia_checkout!(commit, source_dir)
            manyjulias.build!(source_dir, install_dir; nproc=1, echo=(ntasks == 1))
            manyjulias.store!(commit, install_dir)
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

    ntasks = if haskey(opts, "threads")
        parse(Int, opts["threads"])
    else
        Sys.CPU_THREADS
    end

    workdir = if haskey(opts, "workdir")
        abspath(expanduser(opts["workdir"]))
    else
        # NOTE: we use /var/tmp because that's less likely to be backed by tmpfs, as per FHS
        mktempdir("/var/tmp")
    end
    mkpath(workdir)

    # determine wheter to start packing, and from which branch to pack commits
    branch_commits = julia_branch_commits()
    master_branch_version = maximum(keys(branch_commits))
    if isempty(args)
        version = master_branch_version
    elseif length(args) == 1
        version = VersionNumber(args[1])
    else
        usage("Too many arguments")
    end
    start_commit = branch_commits[version]
    if version == master_branch_version
        branch = "master"
    else
        branch = "release-$(version.major).$(version.minor)"
    end
    @info "Packing Julia $version on $branch from commit $start_commit"

    # store elfshaker data in a version-specific directory.
    # this simplifies cleanup, and loose pack management.
    data_dir_suffix = "julia-$(version.major).$(version.minor)"
    if haskey(opts, "datadir")
        data_dir = abspath(expanduser(opts["datadir"]))
        manyjulias.set_data_dir(data_dir; suffix=data_dir_suffix)
    else
        manyjulias.set_data_dir(; suffix=data_dir_suffix)
    end
    @info "Using data directory $(manyjulias.data_dir)"

    # list all commits we care about
    @info "Listing commits..."
    julia = manyjulias.julia_repo()
    commits = let
        commits = String[]
        for line in eachline(`$(git()) -C $julia rev-list --reverse --first-parent $(start_commit)\~..$branch`)
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

    return packs

    return
end

isinteractive() || main(ARGS)
