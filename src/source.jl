# Julia source repository management

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
    bare_repo = julia_repo()

    # Clone from local bare repo (fast, shares objects via hardlinks)
    repo = LibGit2.clone(bare_repo, dir; isbare=false)
    try
        obj = LibGit2.GitObject(repo, commit)
        LibGit2.checkout_tree(repo, obj)
        LibGit2.head!(repo, LibGit2.GitHash(obj))
    finally
        close(repo)
    end

    return dir
end

"""
    julia_checkout_cleanup!(dir)

No-op cleanup function. With local clones (instead of worktrees), cleanup
is handled by simply removing the directory.
"""
function julia_checkout_cleanup!(dir)
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
