
const julia_lock = ReentrantLock()

# Cached LibGit2 repo handle
const _julia_repo_handle = Ref{Union{Nothing, LibGit2.GitRepo}}(nothing)

function julia_repo_handle()
    if _julia_repo_handle[] === nothing || !isdir(LibGit2.gitdir(_julia_repo_handle[]))
        _julia_repo_handle[] = LibGit2.GitRepo(julia_repo())
    end
    return _julia_repo_handle[]
end

function invalidate_repo_handle!()
    if _julia_repo_handle[] !== nothing
        close(_julia_repo_handle[])
        _julia_repo_handle[] = nothing
    end
end

# Fetch master and release-* branches
function _fetch_branches!(remote::LibGit2.GitRemote)
    refspecs = [
        "+refs/heads/master:refs/heads/master",
        "+refs/heads/release-*:refs/heads/release-*"
    ]
    try
        LibGit2.fetch(remote, refspecs)
    finally
        close(remote)
    end
end

# get or clone the Julia repository
function julia_repo()
    dir = joinpath(download_dir, "julia")
    if !ispath(joinpath(dir, "config"))
        lock(julia_lock) do
            if !ispath(joinpath(dir, "config"))
                @info "Performing initial clone of Julia repository..."
                repo = LibGit2.init(dir, #=bare=# true)
                try
                    remote = LibGit2.GitRemote(repo, "origin", "https://github.com/JuliaLang/julia")
                    _fetch_branches!(remote)
                finally
                    close(repo)
                end
                invalidate_repo_handle!()
            end
        end
    end
    return dir
end

# update the Julia repository
function julia_repo_update(; max_age=300, always=false)
    dir = julia_repo()

    # check if we need to update
    if !always && julia_repo_age() <= max_age
        return false
    end

    lock(julia_lock) do
        # re-check inside the lock in case another thread just updated
        if !always && julia_repo_age() <= max_age
            return false
        end

        # Remove gc.log so git's auto-gc can run. Git creates this file when gc
        # fails (e.g., concurrent access, timeout) and won't retry until removed.
        rm(joinpath(dir, "gc.log"); force=true)

        repo = LibGit2.GitRepo(dir)
        try
            remote = LibGit2.lookup_remote(repo, "origin")
            _fetch_branches!(remote)
        finally
            close(repo)
        end

        # Invalidate the cached repo handle in case refs changed
        invalidate_repo_handle!()
    end
    return true
end

# verify whether an object exists
function julia_verify(rev)
    repo = julia_repo_handle()
    try
        LibGit2.GitObject(repo, rev)
        return true
    catch
        return false
    end
end

# the age of the repository in seconds
function julia_repo_age()
    julia = julia_repo()
    time() - stat(joinpath(julia, "FETCH_HEAD")).mtime
end

# lookup a revision specifier
function julia_lookup(rev)
    # if we're looking up a common branch, make sure the repository is up to date
    always = rev == "master" || startswith(rev, "release-")
    updated = julia_repo_update(; always)

    # if the revision we're looking up doesn't exist, try to update first
    if !updated && !julia_verify(rev)
        julia_repo_update(; always=false)
    end

    repo = julia_repo_handle()
    obj = LibGit2.GitObject(repo, rev)
    return string(LibGit2.GitHash(obj))
end

# check-out a specific Julia commit
function julia_checkout!(rev, dir)
    commit = julia_lookup(rev)
    repo = julia_repo_handle()

    # Prune stale worktrees (from previously deleted directories)
    worktree_prune_stale!(repo)

    # Remove any existing worktree with this name (handles interrupted builds
    # where mktempdir recreated a directory with the same name)
    worktree_remove!(repo, basename(dir); force=true)

    # Create detached worktree - fast and shares objects with main repo
    # Detached means no branch, just the commit. If dir is later deleted
    # without cleanup, the next prune will handle it.
    worktree_add!(repo, basename(dir), dir, commit)

    return dir
end

"""
    julia_checkout_cleanup!(dir)

Clean up worktree metadata for a checkout directory.
Safe to call even if worktree was never created or already cleaned up.
"""
function julia_checkout_cleanup!(dir)
    repo = julia_repo_handle()
    worktree_remove!(repo, basename(dir); force=true)
    return nothing
end

# determine the Julia release a commit belongs to.
# this is determined by looking at the VERSION file, so it only identifies the release.
function julia_commit_version(commit)
    repo = julia_repo_handle()
    blob = LibGit2.GitBlob(repo, "$commit:VERSION")
    return VersionNumber(strip(String(LibGit2.content(blob))))
end

# Count commits in range (equivalent to: git rev-list --count end ^start)
function _count_commits(repo, start_commit, end_commit)
    walker = LibGit2.GitRevWalker(repo)
    start_obj = LibGit2.GitObject(repo, start_commit)
    end_obj = LibGit2.GitObject(repo, end_commit)
    start_hash = string(LibGit2.GitHash(start_obj))
    end_hash = string(LibGit2.GitHash(end_obj))
    LibGit2.push!(walker, "$(start_hash)..$(end_hash)")
    return count(_ -> true, walker)
end

# Get the commit that last modified line 1 of a file
function _blame_line1(repo, commit, path)
    # Resolve commit ref to a hash (handles both refs like "master" and full hashes)
    obj = LibGit2.GitObject(repo, commit)
    commit_hash = LibGit2.GitHash(obj)
    opts = LibGit2.BlameOptions(max_line=1, newest_commit=commit_hash)
    blame = LibGit2.GitBlame(repo, path; options=opts)
    hunk = blame[1]
    return string(hunk.orig_commit_id)
end

# Julia version of contrib/commit-name.sh
function julia_commit_name(commit)
    repo = julia_repo_handle()

    version = julia_commit_version(commit)

    branch_commit = _blame_line1(repo, commit, "VERSION")

    commits = _count_commits(repo, branch_commit, commit)

    return "$version.$(commits)"
end

# determine the points where Julia versions branched
function julia_branch_commits()
    repo = julia_repo_handle()

    commit = "master"
    branch_commits = Dict{VersionNumber,String}()
    while !haskey(branch_commits, v"1.6")
        commit = _blame_line1(repo, commit, "VERSION")

        version = julia_commit_version(commit)

        version = Base.thisminor(version)
        @assert !haskey(branch_commits, version)
        branch_commits[version] = commit

        commit = "$(commit)~"
    end

    branch_commits
end

# given a version, figure out which branch to look at
# (e.g. v"1.10" => master, v"1.9" => "release-1.9")
function julia_branch_name(version)
    branch_commits = julia_branch_commits()
    master_branch_version = maximum(keys(branch_commits))

    if version == master_branch_version
        return "master"
    else
        return "release-$(version.major).$(version.minor)"
    end
end

# check if a commit has a VERSION file (helper for filtering)
function _has_version_file(repo, commit_hash)
    try
        LibGit2.GitBlob(repo, "$commit_hash:VERSION")
        return true
    catch
        return false
    end
end

# list all the commits that matter for a given Julia version, sorted oldest to newest
# (i.e., iterating from the branch point to the end of the relevant branch)
function julia_commits(version)
    julia_repo_update()

    branch_commits = julia_branch_commits()
    start_commit = branch_commits[version]
    version_branch = julia_branch_name(version)
    if !julia_verify(version_branch)
        error("Julia branch '$version_branch' does not exist in the repository.")
    end

    repo = julia_repo_handle()

    # Use LibGit2 GitRevWalker for efficient commit traversal
    # NOTE: for the commits to be named uniquely according to julia_commit_name, we'd
    #       need to specify --first-parent in order to exclude merged commits.
    #       however, as that reduces the usefulness (e.g. to bisect backports),
    #       we include all commits, albeit in topological order so that introducing
    #       a merge shouldn't ever invalidate older, finalized packs.
    walker = LibGit2.GitRevWalker(repo)

    # Set topological sorting with reverse (oldest first)
    LibGit2.sort!(walker; by=LibGit2.Consts.SORT_TOPOLOGICAL, rev=true)

    # Push the range from start_commit~ to version_branch
    # This is equivalent to: git rev-list start_commit~..version_branch
    start_obj = LibGit2.GitObject(repo, "$(start_commit)~")
    start_hash = string(LibGit2.GitHash(start_obj))
    branch_obj = LibGit2.GitObject(repo, version_branch)
    branch_hash = string(LibGit2.GitHash(branch_obj))
    LibGit2.push!(walker, "$(start_hash)..$(branch_hash)")

    # Collect commits
    commits = String[]
    for oid in walker
        push!(commits, string(oid))
    end

    # filter out commits without a VERSION file (e.g., from merged external repos)
    filter!(commits) do commit
        _has_version_file(repo, commit)
    end

    return commits
end

# list all the commits for a Julia version, grouped in packs named by the first commit,
# sorted oldest to newest
function julia_commit_packs(version; packsize=250)
    commits = julia_commits(version)

    packs = OrderedDict()
    for commit_chunk in Iterators.partition(commits, packsize)
        packs[julia_commit_name(first(commit_chunk))] = commit_chunk
    end
    return packs
end


## building Julia

struct BuildError <: Exception
    log::String
end

# populate Julia's srccache
const srccache_lock = ReentrantLock()
function populate_srccache!(source_dir)
    srccache = joinpath(download_dir, "srccache")
    mkpath(srccache)

    repo_srccache = joinpath(source_dir, "deps", "srccache")
    lock(srccache_lock) do
        # get existing
        cp(srccache, repo_srccache)

        # download new
        rootfs = lock(artifact_lock) do
            artifact"package_linux"
        end
        workdir = mktempdir()
        sandbox_cmd = sandbox(`/bin/bash -l`; workdir, rootfs,
                              mounts=Dict("/source:rw" => source_dir),
                              uid=1000, gid=1000, cwd="/source")
        try
            output_buf = IOBuffer()
            input = Pipe()

            cmd = pipeline(sandbox_cmd; stdin=input, stdout=output_buf, stderr=output_buf)
            proc = run(cmd; wait=false)

            println(input, """
                set -ue

                # Julia 1.6 requires a functional gfortran, but only for triple detection
                echo 'echo "GNU Fortran (GCC) 9.0.0"' > /usr/local/bin/gfortran
                chmod +x /usr/local/bin/gfortran

                make -C deps getall NO_GIT=1""")
            close(input)

            wait(proc)

            if !success(proc)
                log = String(take!(output_buf))
                @warn "Failed to populate srccache:\n$log"
            end
        finally
            if VERSION < v"1.9-"    # JuliaLang/julia#47650
                chmod_recursive(workdir, 0o777)
            end
            rm(workdir; recursive=true)
        end

        # sync back
        for file in readdir(repo_srccache)
            if !ispath(joinpath(srccache, file))
                cp(joinpath(repo_srccache, file), joinpath(srccache, file))
            end
        end
    end
end

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

# build a Julia source tree and install it
const artifact_lock = ReentrantLock()   # to prevent concurrent downloads
function build!(source_dir, install_dir; nproc=Sys.CPU_THREADS,
                timeout::Int=3600, asserts::Bool=false)
    populate_srccache!(source_dir)

    # define a Make.user
    open("$source_dir/Make.user", "w") do io
        println(io, "JULIA_CPU_TARGET=$default_cpu_target")

        # make generated code easier to delta-diff
        println(io, "CFLAGS=-ffunction-sections -fdata-sections")
        println(io, "CXXFLAGS=-ffunction-sections -fdata-sections")

        if asserts
            println(io, "FORCE_ASSERTIONS=1")
            println(io, "LLVM_ASSERTIONS=1")
        end
    end

    # Build log will be captured here for use in smoke test
    build_log = ""

    # build and install Julia
    rootfs = lock(artifact_lock) do
        artifact"package_linux"
    end
    workdir = mktempdir()
    name = randstring()
    sandbox_cmd = sandbox(`/bin/bash -l`; name, workdir, rootfs,
                          mounts=Dict("/source:rw" => source_dir,
                                      "/install:rw" => install_dir),
                          env=Dict("nproc" => string(nproc)),
                          uid=1000, gid=1000, cwd="/source")
    try
        output_buf = IOBuffer()
        input = Pipe()

        cmd = pipeline(sandbox_cmd; stdin=input, stdout=output_buf, stderr=output_buf)
        proc = run(cmd; wait=false)

        println(input, raw"""
            set -ue

            # Julia 1.6 requires a functional gfortran, but only for triple detection
            echo 'echo "GNU Fortran (GCC) 9.0.0"' > /usr/local/bin/gfortran
            chmod +x /usr/local/bin/gfortran

            # old releases somtimes contain bad checksums; ignore those
            sed -i 's/exit 2$/exit 0/g' deps/tools/jlchecksum

            # prevent building docs
            echo "default:" > doc/Makefile
            mkdir -p doc/_build/html

            # use binary-dist instead of install as it bundles additional files
            make -j${nproc} binary-dist
            mv julia-*/* /install""")
        close(input)

        # watch for timeouts
        timeout_monitor = Timer(timeout) do timer
            process_running(proc) || return
            # TODO: why doesn't `crun kill --all` work?
            recursive_kill(proc, Base.SIGTERM)
            t = Timer(10) do timer
                recursive_kill(proc, Base.SIGKILL)
            end
            wait(proc)
            close(t)
        end

        wait(proc)
        close(timeout_monitor)
        build_log = String(take!(output_buf))

        if !success(proc)
            throw(BuildError(build_log))
        end
    finally
        if VERSION < v"1.9-"    # JuliaLang/julia#47650
            chmod_recursive(workdir, 0o777)
        end
        rm(workdir; recursive=true)
    end

    # perform a smoke test
    let julia_exe = joinpath(install_dir, "bin", "julia")
        # Helper to generate diagnostic error message
        function smoke_test_error(reason)
            listing = try
                read(`ls -laR $install_dir`, String)
            catch
                "[failed to list directory]"
            end

            build_lines = split(build_log, '\n')
            build_tail = join(build_lines[max(1, end-49):end], '\n')

            throw(BuildError("""
                $reason

                === Installation directory ===
                $listing

                === Build log (last 50 lines) ===
                $build_tail
                """))
        end

        # Check binary exists before trying to run it
        if !isfile(julia_exe)
            smoke_test_error("Julia binary not found at $julia_exe")
        end

        output_buf = IOBuffer()
        cmd = pipeline(ignorestatus(`$julia_exe -e 42`);
                       stdin=devnull, stdout=output_buf, stderr=output_buf)
        proc = run(cmd; wait=false)
        wait(proc)

        if !success(proc)
            smoke_log = String(take!(output_buf))
            smoke_test_error("Could not execute built Julia binary.\n\n=== Smoke test output ===\n$smoke_log")
        end
    end

    # remove some useless stuff
    rm(joinpath(install_dir, "share", "doc"); recursive=true, force=true)
    rm(joinpath(install_dir, "share", "man"); recursive=true, force=true)
end
