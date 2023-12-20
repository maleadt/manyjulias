#!/usr/bin/env julia

using Pkg
Pkg.instantiate()

using manyjulias

const MAX_LOOSE_COMMITS = 32

function usage(error=nothing)
    error !== nothing && println("Error: $error\n")
    println("""
        Usage: manyjulias/bin/$(basename(@__FILE__)) [options] [rev] [julia args]

        This script launches Julia from a given revision, if available in a pack.

        The first positional argument determines which commit of Julia to launch.
        This revision can be specified as a commit SHA, branch or tag name, etc.
        Any remaining arguments are passed to the launched Julia process.

        Options:
            --help              Show this help message.
            --asserts           Use builds with assertions enabled.
            --list              List the available revisions.""")
    exit(error === nothing ? 0 : 1)
end

function list(; asserts::Bool=false)
    stats = []

    branch_commits = manyjulias.julia_branch_commits()
    for version in sort(collect(keys(branch_commits)))
        db = "julia-$(version.major).$(version.minor)"
        if asserts
            db *= "-asserts"
        end
        available_commits = Set(union(manyjulias.list(db).loose,
                                values(manyjulias.list(db).packed)...))
        if !isempty(available_commits)
            push!(stats, (; version,
                            available=length(available_commits),
                            total=length(manyjulias.julia_commits(version))))
        end
    end

    if isempty(stats)
        println("No revisions available.")
    else
        println("Available commits:")
        for stat in stats
            println("- Julia $(stat.version.major).$(stat.version.minor): $(stat.available)/$(stat.total) commits")
        end
    end

    println()
    println("To build more commits, execute `manyjulias/bin/build.jl RELEASE`.")

    exit(0)
end

function main(all_args...)
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
    for opt in keys(opts)
        if !in(opt, ["help", "asserts", "list"])
            usage("Unknown option '$opt'")
        end
    end
    asserts = haskey(opts, "asserts")
    haskey(opts, "help") && usage()
    haskey(opts, "list") && list(; asserts)

    # determine the commit and its release version
    if isempty(args)
        usage("Missing revision argument")
    elseif length(args) > 1
        usage("Too many arguments")
    end
    rev = args[1]
    commit = manyjulias.julia_lookup(rev)
    if rev != commit
        @info "Translated requested revision $rev to commit $commit"
    end
    version = manyjulias.julia_commit_version(commit)
    db = "julia-$(version.major).$(version.minor)"
    if asserts
        db *= "-asserts"
    end

    # check if we have this commit
    available_commits = Set(union(manyjulias.list(db).loose,
                                  values(manyjulias.list(db).packed)...))
    if commit ∉ available_commits
        @error("Commit $commit is not available in any pack. Run `manyjulias/bin/build.jl $(version.major).$(version.minor)` to generate it.")
        exit(125)
    end

    launch(commit, child_args; db)
end

function launch(commit, child_args; db)
    dir = mktempdir()

    proc = try
        manyjulias.extract_readonly!(db, commit, dir)

        cmd = ignorestatus(`$(joinpath(dir, "bin", "julia")) $(child_args)`)
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

isinteractive() || main(ARGS...)
