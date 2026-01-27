# Status command - show available commits and build status

const STATUS_COMMAND_NAME = "status"
const STATUS_COMMAND_DESC = "Show available commits and build status"

function status_usage()
    return """
        Usage: manyjulias status [options] [release]

        Summarize the available revisions for builds.

        Pass a release (e.g., "1.10") as positional argument to list individual commits.

        Options:
            --help              Show this help message.
            --asserts           Show assertion-enabled builds."""
end

function status_main(args)
    args, opts = parse_args(args)
    for opt in keys(opts)
        if !in(opt, ["help", "asserts"])
            println("Error: Unknown option '$opt'\n")
            println(status_usage())
            return 1
        end
    end
    if haskey(opts, "help")
        println(status_usage())
        return 0
    end
    asserts = haskey(opts, "asserts")

    version = isempty(args) ? nothing : args[1]
    status_show(version; asserts)
    return 0
end

function status_show(version=nothing; asserts::Bool=false)
    stats = []

    if version === nothing
        branch_commits = julia_branch_commits()
        for version in sort(collect(keys(branch_commits)))
            db = "julia-$(version.major).$(version.minor)"
            if asserts
                db *= "-asserts"
            end

            # Get available commits
            db_list = list(db)
            loose_commits = db_list.loose
            packed_commits = isempty(db_list.packed) ? String[] : union(values(db_list.packed)...)
            available_commits = Set(union(loose_commits, packed_commits))

            if !isempty(available_commits)
                # Determine which commits would actually be built
                all_commits = julia_commits(version)
                packs = julia_commit_packs(version)
                unbuilt_commits = String[]

                for (pack_name, commit_chunk) in packs
                    safe_pack_name = safe_name("julia-$(pack_name)")
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
        println("To list the actual commits, run `manyjulias status RELEASE`.")
    else
        # Parse version if it's a string
        if isa(version, AbstractString)
            version = VersionNumber(version)
        end

        db = "julia-$(version.major).$(version.minor)"
        if asserts
            db *= "-asserts"
        end
        db_list = list(db)
        loose_commits = db_list.loose
        packed_commits = isempty(db_list.packed) ? String[] : union(values(db_list.packed)...)
        available_commits = Set(union(loose_commits, packed_commits))

        if isempty(available_commits)
            println("No commits available for Julia $(version.major).$(version.minor).")
        else
            println("Available commits for Julia $(version.major).$(version.minor):")
            all_commits = julia_commits(version)
            for commit in all_commits
                if commit in available_commits
                    println("- $commit")
                end
            end
        end
    end

    println()
    println("To build more commits, run `manyjulias build RELEASE`.")
end
