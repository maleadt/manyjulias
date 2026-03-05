# Build command - build Julia packs for releases

using ProgressMeter

function format_duration(seconds::Real)
    if seconds < 60
        return "$(round(Int, seconds))s"
    elseif seconds < 3600
        m, s = divrem(round(Int, seconds), 60)
        return "$(m)m $(s)s"
    else
        h, rem = divrem(round(Int, seconds), 3600)
        m, s = divrem(rem, 60)
        return "$(h)h $(m)m $(s)s"
    end
end

const MAX_BUILD_RETRIES = 3

function failures_path(db::String)
    joinpath(data_dir, db, "failures.toml")
end

function load_failures(db::String)
    path = failures_path(db)
    isfile(path) ? Dict{String,Int}(k => v for (k, v) in TOML.parsefile(path)) :
                   Dict{String,Int}()
end

function save_failures!(db::String, failures::Dict{String,Int})
    mkpath(joinpath(data_dir, db))
    open(failures_path(db), "w") do io
        TOML.print(io, failures)
    end
end

const BUILD_COMMAND_NAME = "build"
const BUILD_COMMAND_DESC = "Build Julia packs for releases"

function build_usage()
    return """
        Usage: manyjulias build [options] [releases...]

        Generate manyjulias packs for given Julia releases.

        Version specifiers:
            1.10            Build a specific version.
            1.10+           Build version 1.10 and all newer versions.
            1.10-1.12       Build versions 1.10 through 1.12 (inclusive).

        Options:
            --help              Show this help message.
            --work-dir          Temporary storage location.
            --asserts           Build with assertions enabled.
            --jobs=<n>, -j<n>   Number of parallel builds (default: $(Sys.CPU_THREADS)).
            --threads=<n>       Number of threads per build (default: 1).
            --rebuild     Rebuild incomplete packs to fill in missing commits."""
end

function build_main(args)
    args, opts = parse_args(args)
    for opt in keys(opts)
        if !in(opt, ["help", "work-dir", "asserts", "jobs", "j", "threads", "rebuild"])
            println("Error: Unknown option '$opt'\n")
            println(build_usage())
            return 1
        end
    end
    if haskey(opts, "help")
        println(build_usage())
        return 0
    end
    asserts = haskey(opts, "asserts")
    rebuild = haskey(opts, "rebuild")

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

    # No arguments: show help
    if isempty(args)
        println(build_usage())
        return 0
    end

    # Parse version specifiers
    # Only one range specifier (1.10+ or 1.10-1.12) is allowed
    range_args = filter(a -> endswith(a, '+') || contains(a, '-'), args)
    if length(range_args) > 1
        println("Error: Only one version range specifier is allowed (got: $(join(range_args, ", ")))")
        return 1
    end

    branch_commits = nothing  # lazy-load only if needed
    versions = VersionNumber[]
    for arg in args
        if endswith(arg, '+')
            # "1.10+" syntax: from this version onward
            min_version = VersionNumber(arg[1:end-1])
            if isnothing(branch_commits)
                branch_commits = julia_branch_commits()
            end
            all_versions = sort(collect(keys(branch_commits)))
            matching = filter(v -> v >= min_version, all_versions)
            if isempty(matching)
                println("Error: No versions found >= $min_version")
                return 1
            end
            append!(versions, matching)
        elseif contains(arg, '-')
            # "1.10-1.12" syntax: version range
            parts = split(arg, '-'; limit=2)
            min_version = VersionNumber(parts[1])
            max_version = VersionNumber(parts[2])
            if min_version > max_version
                println("Error: Invalid range $arg (start > end)")
                return 1
            end
            if isnothing(branch_commits)
                branch_commits = julia_branch_commits()
            end
            all_versions = sort(collect(keys(branch_commits)))
            matching = filter(v -> min_version <= v <= max_version, all_versions)
            if isempty(matching)
                println("Error: No versions found in range $min_version to $max_version")
                return 1
            end
            append!(versions, matching)
        else
            # Specific version
            push!(versions, VersionNumber(arg))
        end
    end
    versions = sort(unique(versions))

    if length(versions) > 1
        @info "Building $(length(versions)) version(s): $(join(versions, ", "))"
    end

    failed_versions = VersionNumber[]
    for version in versions
        try
            build_version(version; work_dir, njobs, nthreads, asserts, rebuild)
        catch err
            @error "Failed to build Julia $version" exception=(err, catch_backtrace())
            push!(failed_versions, version)
        end
    end

    if !isempty(failed_versions)
        @warn "Failed to build $(length(failed_versions)) version(s): $(join(failed_versions, ", "))"
        return 1
    end

    return 0
end

function build_version(version::VersionNumber; work_dir::String, njobs::Int,
                       nthreads::Int, asserts::Bool=false, rebuild::Bool=false)
    @info "Building packs for Julia $version (asserts=$asserts)"
    db = "julia-$(version.major).$(version.minor)"
    if asserts
        db *= "-asserts"
    end

    # Check write permissions early
    db_dir = joinpath(data_dir, db)
    check_dir = isdir(db_dir) ? db_dir : data_dir
    if !iswritable(check_dir)
        error("You do not have permission to write to the data directory at '$check_dir'")
    end
    mkpath(db_dir)

    failures = load_failures(db)

    # determine packs we want
    packs = julia_commit_packs(version)
    packs_available = list(db).packed

    # create each pack
    for (i, (pack_name, commit_chunk)) in enumerate(packs)
        safe_pack_name = safe_name("julia-$(pack_name)")

        if haskey(packs_available, safe_pack_name)
            pack_commits = packs_available[safe_pack_name]
            missing = length(commit_chunk) - length(pack_commits)

            if missing > 0 && rebuild
                # check if any missing commits are eligible for retry
                packed_set = Set(pack_commits)
                eligible = count(commit_chunk) do commit
                    commit ∉ packed_set && get(failures, commit, 0) < MAX_BUILD_RETRIES
                end
                if eligible > 0
                    @info "Pack $i/$(length(packs)) ($pack_name): $missing missing, $eligible eligible for retry; rebuilding"
                else
                    @info "Pack $i/$(length(packs)) ($pack_name): $missing missing, all permanently failed"
                    continue
                end
            else
                @info "Pack $i/$(length(packs)) ($pack_name): already created, containing $(length(pack_commits))/$(length(commit_chunk)) commits"
                continue
            end
        end

        @info "Creating pack $i/$(length(packs)) ($pack_name) containing $(length(commit_chunk)) commits"
        build_pack(commit_chunk; work_dir, njobs, nthreads, db, asserts, failures,
                   old_pack=haskey(packs_available, safe_pack_name) ? safe_pack_name : nothing)
        save_failures!(db, failures)

        # close all but the final pack
        if i !== length(packs)
            @info "Finalizing pack $pack_name"
            pack(db, safe_pack_name)
            rm_loose(db)
        end
    end
end

function build_pack(commits; work_dir::String, njobs::Int, nthreads::Int,
                    db::String, asserts::Bool,
                    failures::Dict{String,Int}=Dict{String,Int}(),
                    old_pack::Union{String,Nothing}=nothing)
    # check if we need to clean the slate
    unrelated_loose_commits = filter(list(db).loose) do commit
        !(commit in commits)
    end
    if !isempty(unrelated_loose_commits)
        @warn "$(length(unrelated_loose_commits)) unrelated loose commits detected; removing"
        rm_loose(db)
        # XXX: this may remove too much, but I don't think it's possible to remove select
        #      loose commits, as there's both the indices and the actual objects.
        #      elfshaker gc would help here (elfshaker/elfshaker#97)
    end

    # recover commits from the old pack before deleting it
    if old_pack !== nothing
        old_commits = list(db).packed[old_pack]
        @info "Recovering $(length(old_commits)) commits from $old_pack"
        p = Progress(length(old_commits); desc="Recovering commits: ")
        for commit in old_commits
            dir = mktempdir(work_dir)
            extract!(db, commit, dir)
            store!(db, commit, dir)
            next!(p)
        end
        rm_pack!(db, old_pack)
    end

    loose_commits = Set(list(db).loose)
    @assert all(in(commits), loose_commits)

    # filter out already-built and permanently-failed commits
    commits_to_build = filter(commits) do commit
        commit ∉ loose_commits && get(failures, commit, 0) < MAX_BUILD_RETRIES
    end
    isempty(commits_to_build) && return
    skipped = length(commits) - length(loose_commits) - length(commits_to_build)
    if skipped > 0
        @info "Building $(length(commits_to_build)) commits ($njobs builds in parallel, $nthreads threads each), skipping $skipped permanently failed"
    else
        @info "Building $(length(commits_to_build)) commits ($njobs builds in parallel, $nthreads threads each)"
    end
    failures_lock = ReentrantLock()
    p = Progress(length(commits_to_build); desc="Building pack: ")
    asyncmap(commits_to_build; ntasks=njobs) do commit
        source_dir = mktempdir(work_dir; prefix="$(commit)_")
        install_dir = mktempdir(work_dir; prefix="$(commit)_")
        start_time = time()

        try
            julia_checkout!(commit, source_dir)
            build!(source_dir, install_dir; nproc=nthreads, asserts)
            store!(db, commit, install_dir)
            lock(failures_lock) do
                delete!(failures, commit)
            end
        catch err
            if !isa(err, BuildError)
                @error "Unexpected error while building $commit" exception=(err, catch_backtrace())
                rethrow(err)
            end

            lock(failures_lock) do
                failures[commit] = get(failures, commit, 0) + 1
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

            duration_str = format_duration(time() - start_time)
            err_lines = split(err.log, '\n')
            err_tail = join(err_lines[max(1, end-99):end], '\n')
            @error "Failed to build $commit ($reason_str, $exit_info, $duration_str):\n$err_tail"
        finally
            rm(source_dir; recursive=true, force=true)
            rm(install_dir; recursive=true, force=true)
            next!(p)
        end
    end
end
