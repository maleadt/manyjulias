# building Julia

struct BuildError <: Exception
    log::String
    reason::Symbol      # :build_failed, :timeout, :smoke_test_failed
    exitcode::Int       # Process exit code (-1 if killed by signal or unknown)
    termsignal::Int     # Signal that killed process (0 if normal exit)
end

# Convenience constructor for backwards compatibility
BuildError(log::String) = BuildError(log, :build_failed, -1, 0)

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
        workdir = mktempdir("/var/tmp")
        sandbox_cmd = sandbox(`/bin/bash -l`; workdir, rootfs,
                              mounts=Dict("/source:rw" => source_dir),
                              uid=1000, gid=1000, cwd="/source")
        try
            log_file = joinpath(workdir, "srccache.log")
            input = Pipe()

            cmd = pipeline(sandbox_cmd; stdin=input, stdout=log_file, stderr=log_file)
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
                log = isfile(log_file) ? read(log_file, String) : ""
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
    workdir = mktempdir("/var/tmp")
    name = randstring()
    sandbox_cmd = sandbox(`/bin/bash -l`; name, workdir, rootfs,
                          mounts=Dict("/source:rw" => source_dir,
                                      "/install:rw" => install_dir),
                          env=Dict("nproc" => string(nproc)),
                          uid=1000, gid=1000, cwd="/source")
    try
        log_file = joinpath(workdir, "build.log")
        input = Pipe()

        cmd = pipeline(sandbox_cmd; stdin=input, stdout=log_file, stderr=log_file)
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
        timed_out = Ref(false)
        timeout_monitor = Timer(timeout) do timer
            process_running(proc) || return
            timed_out[] = true
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
        build_log = isfile(log_file) ? read(log_file, String) : ""

        if !success(proc)
            reason = timed_out[] ? :timeout : :build_failed
            exitcode = proc.exitcode
            termsignal = proc.termsignal
            throw(BuildError(build_log, reason, exitcode, termsignal))
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
        function smoke_test_error(reason; exitcode::Int=-1, termsignal::Int=0)
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
                """, :smoke_test_failed, exitcode, termsignal))
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
            smoke_test_error("Could not execute built Julia binary.\n\n=== Smoke test output ===\n$smoke_log";
                             exitcode=proc.exitcode, termsignal=proc.termsignal)
        end
    end

    # remove some useless stuff
    rm(joinpath(install_dir, "share", "doc"); recursive=true, force=true)
    rm(joinpath(install_dir, "share", "man"); recursive=true, force=true)
end
