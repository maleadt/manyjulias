#!/usr/bin/env julia

using Pkg
Pkg.activate(dirname(@__DIR__))

using manyjulias

const MAX_LOOSE_COMMITS = 32

function usage(error=nothing)
    error !== nothing && println("Error: $error\n")
    println("""
        Usage: $(basename(@__FILE__)) [options] [commit] [julia args]

        This script extracts and launches Julia from a given commit.

        The first positional argument determines which commit of Julia to launch.
        Any remaining arguments are passed to the launched Julia process.

        Options:
            --help              Show this help message
            --data-dir          Where to store the generated packs.""")
    exit(error === nothing ? 0 : 1)
end

function main(all_args)
    # split args based on the first positional one
    # XXX: using `--` is cleaner, but doesn't work (JuliaLang/julia#48269)
    args = String[]
    for_child = false
    child_args = String[]
    for arg in all_args
        if for_child
            push!(child_args, arg)
        else
            push!(args, arg)
            if !startswith(arg, "-")
                for_child = true
            end
        end
    end

    args, opts = manyjulias.parse_args(args)
    haskey(opts, "help") && usage()

    # determine the commit and its release version
    if isempty(args)
        usage("Missing commit argument")
    elseif length(args) > 1
        usage("Too many arguments")
    end
    commit = args[1]
    version = manyjulias.julia_commit_version(commit)

    # determine the data directory
    data_dir_suffix = "julia-$(version.major).$(version.minor)"
    if haskey(opts, "datadir")
        data_dir = abspath(expanduser(opts["datadir"]))
        manyjulias.set_data_dir(data_dir; suffix=data_dir_suffix)
    else
        manyjulias.set_data_dir(; suffix=data_dir_suffix)
    end

    # check if we have this commit
    available_commits = Set(union(manyjulias.list().loose,
                                  values(manyjulias.list().packed)...))
    if commit ∉ available_commits
        error("Commit $commit is not available in any pack. Run `manyjulias/bin/build.jl $(version.major).$(version.minor)` to generate it.")
    end

    # if the commit is not available as a loose pack, we need to extract it from a pack.
    loose_commits = manyjulias.list().loose
    if commit ∉ loose_commits
        # we'll need to extract it from a pack,
        # so make sure the datadir doesn't grow too large
        if length(loose_commits) > MAX_LOOSE_COMMITS
            manyjulias.rm_loose()
        end
    end

    # now extract the commit (from a pack, or just the loose pack) and launch it
    if commit in loose_commits
        return launch_loose(commit, child_args)
    end

    # otherwise we first need to extract it from a pack

end

function launch_loose(commit, child_args)
    dir = mktempdir()

    proc = try
        manyjulias.extract!(commit, dir)

        cmd = ignorestatus(`$(joinpath(dir, "bin", "julia")) $(child_args...)`)
        run(cmd)
    finally
        rm(dir; recursive=true, force=true)
    end

    # if the parent process is interactive, we shouldn't exit if the child process failed.
    if isinteractive()
        return
    end

    if success(proc)
        exit(0)
    else
        # Return the exit code if that is nonzero
        if proc.exitcode != 0
            exit(proc.exitcode)
        end

        # If the child instead signalled, we recreate the same signal in ourselves
        # by first disabling Julia's signal handling and then killing ourselves.
        ccall(:sigaction, Cint, (Cint, Ptr{Cvoid}, Ptr{Cvoid}), proc.termsignal, C_NULL, C_NULL)
        ccall(:kill, Cint, (Cint, Cint), getpid(), proc.termsignal)
    end
end

isinteractive() || main(ARGS)
