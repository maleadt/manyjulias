#!/usr/bin/env julia

using Pkg
Pkg.activate(dirname(@__DIR__))

try
    using manyjulias
catch err
    Pkg.instantiate()
    using manyjulias
end

using ProgressMeter

function build_version(version::VersionNumber; work_dir::String, ntasks::Int)
    @info "Building packs for Julia $version"
    db = "julia-$(version.major).$(version.minor)"

    # determine packs we want
    packs = manyjulias.julia_commit_packs(version)
    packs_available = manyjulias.list(db).packed

    # create each pack
    existing_packs = manyjulias.list(db).packed
    for (i, (pack_name, commit_chunk)) in enumerate(packs)
        # if this pack already exists, skip it
        safe_pack_name = manyjulias.safe_name("julia-$(pack_name)")
        if haskey(packs_available, safe_pack_name)
            @info "Pack $i/$(length(packs)) ($pack_name): already created, containing $(length(packs_available[safe_pack_name]))/$(length(commit_chunk)) commits"
            continue
        end

        @info "Creating pack $i/$(length(packs)) ($pack_name) containing $(length(commit_chunk)) commits"
        build_pack(commit_chunk; work_dir, ntasks, db)

        # close all but the final pack
        if i !== length(packs)
            @info "Finalizing pack $pack_name"
            manyjulias.pack(db, safe_pack_name)
            manyjulias.rm_loose(db)
        end
    end

    manyjulias.update_permissions!(db)
end

function build_pack(commits; work_dir::String, ntasks::Int, db::String)
    # check if we need to clean the slate
    unrelated_loose_commits = filter(manyjulias.list(db).loose) do commit
        !(commit in commits)
    end
    if !isempty(unrelated_loose_commits)
        @warn "$(length(unrelated_loose_commits)) unrelated loose commits detected; removing"
        manyjulias.rm_loose(db)
        # XXX: this may remove too much, but I don't think it's possible to remove select
        #      loose commits, as there's both the indices and the actual objects.
        #      elfshaker gc would help here (elfshaker/elfshaker#97)
    end
    loose_commits = manyjulias.list(db).loose

    # re-extract any packed commits we'll need again
    packs = manyjulias.list(db).packed
    packed_commits = isempty(packs) ? [] : union(values(packs)...)
    required_packed_commits = filter(commits) do commit
        commit in packed_commits && !(commit in loose_commits)
    end
    for commit in required_packed_commits
        dir = mktempdir(work_dir)
        manyjulias.extract!(db, commit, dir)
        manyjulias.store!(db, commit, dir)
    end
    loose_commits = manyjulias.list(db).loose

    # the remaining commits need to be built
    commits_to_build = filter(commits) do commit
        !(commit in loose_commits)
    end
    @info "Building $(length(commits_to_build)) commits ($ntasks builds in parallel)"
    p = Progress(length(commits_to_build); desc="Building pack: ")
    asyncmap(commits_to_build; ntasks) do commit
        source_dir = mktempdir(work_dir)
        install_dir = mktempdir(work_dir)

        try
            manyjulias.julia_checkout!(commit, source_dir)
            manyjulias.build!(source_dir, install_dir; nproc=1, echo=(ntasks == 1))
            manyjulias.store!(db, commit, install_dir)
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
        Usage: manyjulias/bin/$(basename(@__FILE__)) [options] [releases]

        This script generates the manyjulias packs for given Julia releases.

        The positional release arguments should be valid version numbers that refer to a
        Julia release (e.g., "1.9"). It defaults to the current development version.

        Options:
            --help              Show this help message
            --work-dir          Temporary storage location.
            --threads=<n>       Use <n> threads for building (default: $(Sys.CPU_THREADS)).""")
    exit(error === nothing ? 0 : 1)
end

function main(args...; update=true)
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

    # determine which versions to build
    versions = VersionNumber.(args)
    if isempty(versions)
        branch_commits = manyjulias.julia_branch_commits()
        versions = [maximum(keys(branch_commits))]
    end

    for version in versions
        build_version(version; work_dir, ntasks)
    end

    return
end

isinteractive() || main(ARGS...)
