
const julia_updated = Ref(false)
const julia_lock = ReentrantLock()

# get an updated Julia (mirror) repository
function julia_repo()
    dir = joinpath(download_dir, "julia")
    if !ispath(joinpath(dir, "config")) || !julia_updated[]
        lock(julia_lock) do
            if !ispath(joinpath(dir, "config"))
                @info "Cloning Julia repository..."
                run(`$(git()) clone --mirror --quiet https://github.com/JuliaLang/julia $dir`)
            elseif !julia_updated[]
                @info "Updating Julia repository..."
                run(`$(git()) -C $dir fetch --quiet --force origin`)
            end
        end
    end
    julia_updated[] = true

    return dir
end

# check-out a specific Julia commit
function julia_checkout!(commit, dir)
    julia = julia_repo()

    # check-out the commit
    mkpath(dir)
    run(`$(git()) clone --quiet $julia $dir`)
    run(`$(git()) -C $dir reset --quiet --hard $commit`)
    return dir
end
julia_checkout(commit) = julia_checkout!(commit, mktempdir())

# Julia version of contrib/commit-name.sh
function commit_name(julia, commit)
    version = readchomp(`$(git()) -C $julia show $commit:VERSION`)
    endswith(version, "-DEV") || error("Only commits from the master branch are supported")

    branch_commit = let
        blame = readchomp(`$(git()) -C $julia blame -L ,1 -sl $commit -- VERSION`)
        split(blame)[1]
    end

    commits = let
        count = readchomp(`$(git()) -C $julia rev-list --count $commit "^$branch_commit"`)
        parse(Int, count)
    end

    return "$version.$(commits)"

    return (; version, commits)
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
        config = SandboxConfig(
            Dict("/"        => rootfs),
            Dict("/source"  => source_dir);
            uid=1000, gid=1000, pwd="/source"
        )
        with_executor(UnprivilegedUserNamespacesExecutor) do exe
            input = Pipe()
            output = Pipe()

            cmd = Sandbox.build_executor_command(exe, config, `/bin/bash -l`)
            cmd = pipeline(cmd; stdin=input, stdout=output, stderr=output)
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
function build!(source_dir, install_dir; nproc=Sys.CPU_THREADS, echo::Bool=true)
    populate_srccache!(source_dir)

    # define a Make.user
    open("$source_dir/Make.user", "w") do io
        println(io, "prefix=/install")
        println(io, "JULIA_CPU_TARGET=$default_cpu_target")

        # make generated code easier to delta-diff
        println(io, "CFLAGS=-ffunction-sections -fdata-sections")
        println(io, "CXXFLAGS=-ffunction-sections -fdata-sections")
    end

    # build and install Julia
    rootfs = lock(artifact_lock) do
        artifact"package_linux"
    end
    config = SandboxConfig(
        # ro
        Dict("/"        => rootfs),
        # rw
        Dict("/source"  => source_dir,
             "/install" => install_dir),
        Dict("nproc"    => string(nproc));
        uid=1000, gid=1000, pwd="/source"
    )
    with_executor(UnprivilegedUserNamespacesExecutor) do exe
        input = Pipe()
        output = Pipe()

        cmd = Sandbox.build_executor_command(exe, config, `/bin/bash -l`)
        cmd = pipeline(cmd; stdin=input, stdout=output, stderr=output)
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

        wait(proc)
        close(output)
        log = fetch(log_monitor)

        if !success(proc)
            throw(BuildError(log))
        end
    end

    # remove some useless stuff
    rm(joinpath(install_dir, "share", "doc"); recursive=true, force=true)
    rm(joinpath(install_dir, "share", "man"); recursive=true, force=true)
end
