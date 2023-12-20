
const julia_lock = ReentrantLock()

# get or clone the Julia repository
function julia_repo()
    dir = joinpath(download_dir, "julia")
    if !ispath(joinpath(dir, "config"))
        lock(julia_lock) do
            if !ispath(joinpath(dir, "config"))
                @info "Performing initial clone of Julia repository..."
                run(`$(git()) clone --mirror --quiet https://github.com/JuliaLang/julia $dir`)
            end
        end
    end
    return dir
end

# update the Julia repository
function julia_repo_update()
    dir = julia_repo()
    lock(julia_lock) do
        @info "Updating Julia repository..."
        rm(joinpath(dir, "gc.log"); force=true)
        run(`$(git()) -C $dir fetch --quiet --force origin`)
    end
    return
end

# verify whether an object exists
function julia_verify(rev)
    julia = julia_repo()
    success(`$(git()) -C $julia rev-parse --verify --quiet $rev --`)
end

# the age of the repository in seconds
function julia_repo_age()
    julia = julia_repo()
    time() - stat(joinpath(julia, "FETCH_HEAD")).mtime
end

# lookup a revision specifier
function julia_lookup(rev)
    julia = julia_repo()

    # if we're looking up a common branch, make sure the repository is up to date
    if (rev == "master" || startswith(rev, "release-")) && julia_repo_age() > 300
        julia_repo_update()

    # if the revision we're looking up doesn't exist, try to update first
    elseif !julia_verify(rev)
        julia_repo_update()
    end

    return split(read(`$(git()) -C $julia rev-parse $rev --`, String), '\n')[1]
end

# check-out a specific Julia commit
function julia_checkout!(rev, dir)
    julia = julia_repo()
    commit = julia_lookup(rev)

    # check-out the commit
    mkpath(dir)
    run(`$(git()) clone --quiet $julia $dir`)
    run(`$(git()) -C $dir reset --quiet --hard $commit`)
    return dir
end

# determine the Julia release a commit belongs to.
# this is determined by looking at the VERSION file, so it only identifies the release.
function julia_commit_version(commit)
    julia = julia_repo()
    return VersionNumber(readchomp(`$(git()) -C $julia show $commit:VERSION`))
end

# Julia version of contrib/commit-name.sh
function julia_commit_name(commit)
    julia = julia_repo()

    version = julia_commit_version(commit)

    branch_commit = let
        blame = readchomp(`$(git()) -C $julia blame -L ,1 -sl $commit -- VERSION`)
        split(blame)[1]
    end

    commits = let
        count = readchomp(`$(git()) -C $julia rev-list --count $commit "^$branch_commit"`)
        parse(Int, count)
    end

    return "$version.$(commits)"
end

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

# list all the commits that matter for a given Julia version, sorted oldest to newest
# (i.e., iterating from the branch point to the end of the relevant branch)
function julia_commits(version)
    julia = manyjulias.julia_repo()
    julia_repo_update()

    branch_commits = julia_branch_commits()
    start_commit = branch_commits[version]
    version_branch = julia_branch_name(version)

    commits = String[]
    for line in eachline(`$(git()) -C $julia rev-list --reverse --topo-order $(start_commit)\~..$version_branch`)
        # NOTE: for the commits to be named uniquely according to julia_commit_name, we'd
        #       need to specify --first-parent in order to exclude merged commits.
        #       however, as that reduces the usefulness (e.g. to bisect backports),
        #       we include all commits, albeit in topological order so that introducing
        #       a merge shouldn't ever invalidate older, finalized packs.
        push!(commits, line)
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
            input = Pipe()
            output = Pipe()

            cmd = pipeline(sandbox_cmd; stdin=input, stdout=output, stderr=output)
            proc = run(cmd; wait=false)

            println(input, """
                set -ue

                # Julia 1.6 requires a functional gfortran, but only for triple detection
                echo 'echo "GNU Fortran (GCC) 9.0.0"' > /usr/local/bin/gfortran
                chmod +x /usr/local/bin/gfortran

                make -C deps getall NO_GIT=1""")
            close(input)

            # collect output
            close(output.in)
            log_monitor = @async String(read(output))

            wait(proc)
            close(output)
            log = fetch(log_monitor)

            if !success(proc)
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
function build!(source_dir, install_dir; nproc=Sys.CPU_THREADS, echo::Bool=true,
                timeout::Int=3600, asserts::Bool=false)
    populate_srccache!(source_dir)

    # define a Make.user
    open("$source_dir/Make.user", "w") do io
        println(io, "prefix=/install")
        println(io, "JULIA_CPU_TARGET=$default_cpu_target")

        # make generated code easier to delta-diff
        println(io, "CFLAGS=-ffunction-sections -fdata-sections")
        println(io, "CXXFLAGS=-ffunction-sections -fdata-sections")

        if asserts
            println(io, "FORCE_ASSERTIONS=1")
            println(io, "LLVM_ASSERTIONS=1")
        end
    end

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
        input = Pipe()
        output = Pipe()

        cmd = pipeline(sandbox_cmd; stdin=input, stdout=output, stderr=output)
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

            make -j${nproc} install

            contrib/fixup-libgfortran.sh /install/lib/julia
            contrib/fixup-libstdc++.sh /install/lib /install/lib/julia""")
        close(input)

        # collect output
        close(output.in)
        log_monitor = @async begin
            io = IOBuffer()
            while !eof(output)
                line = readline(output; keep=true)
                echo && print(line)
                print(io, line)
            end
            return String(take!(io))
        end

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
        close(output)
        close(timeout_monitor)
        log = fetch(log_monitor)

        if !success(proc)
            throw(BuildError(log))
        end
    finally
        if VERSION < v"1.9-"    # JuliaLang/julia#47650
            chmod_recursive(workdir, 0o777)
        end
        rm(workdir; recursive=true)
    end

    # remove some useless stuff
    rm(joinpath(install_dir, "share", "doc"); recursive=true, force=true)
    rm(joinpath(install_dir, "share", "man"); recursive=true, force=true)
end
