#!/usr/bin/env julia

try
    using manyjulias
catch
    using Pkg
    Pkg.instantiate()
    using manyjulias
end

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
            --status            Summarize the available revisions for this build type.
                                Pass the release as positional argument to list revisions.""")
    exit(error === nothing ? 0 : 1)
end

function status(version=nothing; asserts::Bool=false)
    stats = []

    if version === nothing
        branch_commits = manyjulias.julia_branch_commits()
        for version in sort(collect(keys(branch_commits)))
            db = "julia-$(version.major).$(version.minor)"
            if asserts
                db *= "-asserts"
            end

            # Get available commits
            db_list = manyjulias.list(db)
            loose_commits = db_list.loose
            packed_commits = isempty(db_list.packed) ? String[] : union(values(db_list.packed)...)
            available_commits = Set(union(loose_commits, packed_commits))

            if !isempty(available_commits)
                # Determine which commits would actually be built
                all_commits = manyjulias.julia_commits(version)
                packs = manyjulias.julia_commit_packs(version)
                unbuilt_commits = String[]

                for (pack_name, commit_chunk) in packs
                    safe_pack_name = manyjulias.safe_name("julia-$(pack_name)")
                    if !haskey(db_list.packed, safe_pack_name)
                        # Pack doesn't exist - find commits to build
                        last_built_idx = findlast(in(loose_commits), commit_chunk)
                        commits_to_build = isnothing(last_built_idx) ? commit_chunk : commit_chunk[last_built_idx+1:end]
                        append!(unbuilt_commits, commits_to_build)
                    end
                end

                # Get commit ranges
                ordered_available = [c for c in all_commits if c in available_commits]
                ordered_unbuilt = [c for c in all_commits if c in unbuilt_commits]

                push!(stats, (; version,
                                available=length(available_commits),
                                unbuilt=length(unbuilt_commits),
                                num_packs=length(db_list.packed),
                                num_loose=length(loose_commits),
                                first_avail=isempty(ordered_available) ? nothing : first(ordered_available)[1:7],
                                last_avail=isempty(ordered_available) ? nothing : last(ordered_available)[1:7],
                                first_unbuilt=isempty(ordered_unbuilt) ? nothing : first(ordered_unbuilt)[1:7],
                                last_unbuilt=isempty(ordered_unbuilt) ? nothing : last(ordered_unbuilt)[1:7]))
            end
        end

        if isempty(stats)
            println("No commits available.")
        else
            println("Available commits:")
            for stat in stats
                io = IOBuffer()
                print(io, "- Julia $(stat.version.major).$(stat.version.minor): ")

                # Available commits
                print(io, "$(stat.available) commit$(stat.available == 1 ? "" : "s") available (")
                if stat.first_avail !== nothing && stat.last_avail !== nothing
                    if stat.first_avail == stat.last_avail
                        print(io, stat.first_avail)
                    else
                        print(io, "$(stat.first_avail)..$(stat.last_avail)")
                    end
                else
                    print(io, "none")
                end
                print(io, ", ")

                # Packs and loose
                if stat.num_packs > 0
                    print(io, "$(stat.num_packs) pack$(stat.num_packs == 1 ? "" : "s") + ")
                end
                print(io, "$(stat.num_loose) loose commit$(stat.num_loose == 1 ? "" : "s"))")

                # Unbuilt commits
                if stat.unbuilt > 0
                    print(io, ", $(stat.unbuilt) unbuilt (")
                    if stat.first_unbuilt == stat.last_unbuilt
                        print(io, stat.first_unbuilt)
                    else
                        print(io, "$(stat.first_unbuilt)..$(stat.last_unbuilt)")
                    end
                    print(io, ")")
                end

                println(String(take!(io)))
            end
        end

        println()
        println("To list the actual commits, execute `manyjulias/bin/julia.jl --status RELEASE`.")
    else
        # Parse version if it's a string
        if isa(version, AbstractString)
            version = VersionNumber(version)
        end

        db = "julia-$(version.major).$(version.minor)"
        if asserts
            db *= "-asserts"
        end
        db_list = manyjulias.list(db)
        loose_commits = db_list.loose
        packed_commits = isempty(db_list.packed) ? String[] : union(values(db_list.packed)...)
        available_commits = Set(union(loose_commits, packed_commits))

        if isempty(available_commits)
            println("No commits available for Julia $(version.major).$(version.minor).")
        else
            println("Available commits for Julia $(version.major).$(version.minor):")
            all_commits = manyjulias.julia_commits(version)
            for commit in all_commits
                if commit in available_commits
                    println("- $commit")
                end
            end
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
        if !in(opt, ["help", "asserts", "status"])
            usage("Unknown option '$opt'")
        end
    end
    asserts = haskey(opts, "asserts")
    haskey(opts, "help") && usage()
    haskey(opts, "status") && status(args...; asserts)

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
