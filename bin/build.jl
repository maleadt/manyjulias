#!/usr/bin/env julia

try
    using manyjulias
catch
    using Pkg
    Pkg.instantiate()
    using manyjulias
end

using ProgressMeter

function build_version(version::VersionNumber; work_dir::String, njobs::Int,
                       nthreads::Int, asserts::Bool=false)
    @info "Building packs for Julia $version (asserts=$asserts)"
    db = "julia-$(version.major).$(version.minor)"
    if asserts
        db *= "-asserts"
    end

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
        build_pack(commit_chunk; work_dir, njobs, nthreads, db, asserts)

        # close all but the final pack
        if i !== length(packs)
            @info "Finalizing pack $pack_name"
            manyjulias.pack(db, safe_pack_name)
            manyjulias.rm_loose(db)
        end
    end
end

function build_pack(commits; work_dir::String, njobs::Int, nthreads::Int,
                    db::String, asserts::Bool)
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
    @assert all(in(commits), loose_commits)

    # build commits starting from the last successful one
    # (to avoid retrying failed builds unnecessarily)
    last_built_idx = findlast(in(loose_commits), commits)
    commits_to_build = isnothing(last_built_idx) ? commits : commits[last_built_idx+1:end]
    isempty(commits_to_build) && return
    @info "Building $(length(commits_to_build)) commits ($njobs builds in parallel, $nthreads threads each)"
    p = Progress(length(commits_to_build); desc="Building pack: ")
    asyncmap(commits_to_build; ntasks=njobs) do commit
        source_dir = mktempdir(work_dir; prefix="$(commit)_")
        install_dir = mktempdir(work_dir; prefix="$(commit)_")

        try
            manyjulias.julia_checkout!(commit, source_dir)
            manyjulias.build!(source_dir, install_dir; nproc=nthreads, asserts)
            manyjulias.store!(db, commit, install_dir)
        catch err
            if !isa(err, manyjulias.BuildError)
                @error "Unexpected error while building $commit" exception=(err, catch_backtrace())
                rethrow(err)
            end

            # Build diagnostic summary
            reason_str = if err.reason == :timeout
                "TIMEOUT"
            elseif err.reason == :smoke_test_failed
                "SMOKE TEST FAILED"
            else
                "BUILD FAILED"
            end

            exit_info = if err.termsignal != 0
                "killed by signal $(err.termsignal)"
            elseif err.exitcode != -1
                "exit code $(err.exitcode)"
            else
                "unknown exit status"
            end

            err_lines = split(err.log, '\n')
            err_tail = join(err_lines[max(1, end-99):end], '\n')
            @error "Failed to build $commit ($reason_str, $exit_info):\n$err_tail"
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
            --asserts           Build with assertions enabled.
            --jobs=<n>, -j<n>   Number of parallel builds (default: $(Sys.CPU_THREADS)).
            --threads=<n>       Number of threads per build (default: 1).""")
    exit(error === nothing ? 0 : 1)
end

function main(args...)
    args, opts = manyjulias.parse_args(args)
    for opt in keys(opts)
        if !in(opt, ["help", "work-dir", "asserts", "jobs", "j", "threads"])
            usage("Unknown option '$opt'")
        end
    end
    asserts = haskey(opts, "asserts")
    haskey(opts, "help") && usage()

    njobs = if haskey(opts, "jobs")
        parse(Int, opts["jobs"])
    elseif haskey(opts, "j")
        parse(Int, opts["j"])
    else
        Sys.CPU_THREADS
    end

    nthreads = if haskey(opts, "threads")
        parse(Int, opts["threads"])
    else
        1
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
        build_version(version; work_dir, njobs, nthreads, asserts)
    end

    return
end

isinteractive() || main(ARGS...)
