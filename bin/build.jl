#!/usr/bin/env julia

using Pkg
Pkg.activate(dirname(@__DIR__))

using manyjulias
using ProgressMeter

function build_pack(commits_to_pack, commits_to_build; work_dir, ntasks, db)
    # check if we need to clean the slate
    unrelated_loose_commits = filter(manyjulias.list(db).loose) do commit
        !(commit in commits_to_pack)
    end
    if !isempty(unrelated_loose_commits)
        @info "Unrelated loose commits detected; removing"
        manyjulias.rm_loose()
        # XXX: this may remove too much, but I don't think it's possible to remove select
        #      loose commits, as there's both the indices and the actual objects.
        #      elfshaker gc would help here (elfshaker/elfshaker#97)
    end
    loose_commits = manyjulias.list(db).loose

    # re-extract any packed commits we'll need again
    packs = manyjulias.list(db).packed
    packed_commits = isempty(packs) ? [] : union(values(packs)...)
    required_packed_commits = filter(commits_to_pack) do commit
        commit in packed_commits && !(commit in loose_commits)
    end
    for commit in required_packed_commits
        dir = mktempdir(work_dir)
        manyjulias.extract!(db, commit, dir)
        manyjulias.store!(db, commit, dir)
    end
    loose_commits = manyjulias.list(db).loose

    # the remaining commits need to be built
    p = Progress(length(commits_to_pack); desc="Building pack: ",
                 start=length(commits_to_pack) - length(commits_to_build))
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
        Usage: $(basename(@__FILE__)) [options] [release]

        This script generates the manyjulias packs for a given Julia release.

        The positional release argument should be a valid version number that refers to a
        Julia release (e.g., "1.9"). It defaults to the current development version.

        Options:
            --help              Show this help message
            --work-dir          Temporary storage location.
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
    db = "julia-$(version.major).$(version.minor)"

    # determine packs we want
    @info "Structuring in packs..."
    packs = manyjulias.julia_commit_packs(version)

    # find the latest commit we've already stored; we won't pack anything before that
    # so that we avoid discarding loose commits from the final (uncomplete) pack.
    commits = union(values(packs)...)
    available_commits = Set(union(manyjulias.list(db).loose,
                                  values(manyjulias.list(db).packed)...))
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
    existing_packs = manyjulias.list(db).packed
    for (i, (pack_name, commit_chunk)) in enumerate(packs)
        safe_pack_name = manyjulias.safe_name("julia-$(pack_name)")
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
            existing_pack = get(existing_packs, safe_pack_name, [])
            @info "Pack $i/$(length(packs)) ($pack_name): already processed, $(length(existing_pack))/$(length(commit_chunk)) commits built"
            continue
        end
        @info "Pack $i/$(length(packs)) ($pack_name): building $(length(remaining_commits)) commits"
        build_pack(commit_chunk, remaining_commits; work_dir, ntasks, db)

        # close all but the final pack
        if i !== length(packs)
            @info "Closing $pack_name"
            manyjulias.pack(db, safe_pack_name)
            manyjulias.rm_loose(db)
        end
    end

    return
end

isinteractive() || main(ARGS)
