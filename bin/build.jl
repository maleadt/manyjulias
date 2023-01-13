#!/usr/bin/env julia

using Pkg
Pkg.activate(dirname(@__DIR__))

using manyjulias
using ProgressMeter

function build_pack(commits; work_dir, ntasks)
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
        dir = mktempdir(work_dir)
        manyjulias.extract!(commit, dir)
        manyjulias.store!(commit, dir)
    end
    loose_commits = manyjulias.list().loose

    # the remaining commits need to be built
    remaining_commits = filter(commits) do commit
        !(commit in loose_commits)
    end
    p = Progress(length(commits); desc="Building pack: ", start=length(loose_commits))
    asyncmap(remaining_commits; ntasks) do commit
        source_dir = mktempdir(work_dir)
        install_dir = mktempdir(work_dir)
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
end

function usage(error=nothing)
    error !== nothing && println("Error: $error\n")
    println("""
        Usage: $(basename(@__FILE__)) [options] [release]

        This script generates the manyjulias packs for a given Julia release.

        The positional release argument should be a valid version number that refers to a
        Julia release (e.g., "1.9"). It defaults to the current development version.

        Options:
            --help              Show this help message
            --work-dir          Temporary storage location.
            --data-dir          Where to store the generated packs.
            --threads=<n>       Use <n> threads for building (default: $(Sys.CPU_THREADS)).""")
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

    work_dir = if haskey(opts, "work-dir")
        abspath(expanduser(opts["work-dir"]))
    else
        # NOTE: we use /var/tmp because that's less likely to be backed by tmpfs, as per FHS
        mktempdir("/var/tmp")
    end
    mkpath(work_dir)

    # determine wheter to start packing, and from which branch to pack commits
    branch_commits = manyjulias.julia_branch_commits()
    master_branch_version = maximum(keys(branch_commits))
    if isempty(args)
        version = master_branch_version
    elseif length(args) == 1
        version = VersionNumber(args[1])
    else
        usage("Too many arguments")
    end
    @info "Packing Julia $version"

    # store elfshaker data in a version-specific directory.
    # this simplifies cleanup, and loose pack management.
    data_dir_suffix = "julia-$(version.major).$(version.minor)"
    if haskey(opts, "data-dir")
        data_dir = abspath(expanduser(opts["data-dir"]))
        manyjulias.set_data_dir(data_dir; suffix=data_dir_suffix)
    else
        manyjulias.set_data_dir(; suffix=data_dir_suffix)
    end
    @info "Using data directory $(manyjulias.data_dir)"

    # determine packs we want
    @info "Structuring in packs..."
    packs = manyjulias.julia_commit_packs(version)

    # find the latest commit we've already stored; we won't pack anything before that
    # so that we avoid discarding loose commits from the final (uncomplete) pack.
    commits = union(values(packs)...)
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
        @info "Last stored commit: $last_commit ($(manyjulias.julia_commit_name(last_commit)))"
    end

    # create each pack
    for (i, (pack_name, commit_chunk)) in enumerate(packs)
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
        @info "Creating pack $i/$(length(packs)): $pack_name, containing $(length(remaining_commits)) commits"
        build_pack(commit_chunk; work_dir, ntasks)

        # if the pack is complete, finalize it
        if i !== lastindex(packs)
            @info "Closing $pack_name"
            manyjulias.pack(manyjulias.safe_name("julia-$(pack_name)"))
            manyjulias.rm_loose()
        end
    end

    # TODO: don't finalize the last pack, so that we can cheaply add more commits later

    return packs

    return
end

isinteractive() || main(ARGS)
