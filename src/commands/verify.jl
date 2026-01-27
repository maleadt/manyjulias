# Verify command - verify pack integrity

const VERIFY_COMMAND_NAME = "verify"
const VERIFY_COMMAND_DESC = "Verify pack integrity"

function verify_usage()
    return """
        Usage: manyjulias verify [options] [releases...]

        Verify pack integrity against expected contents for Julia releases.

        If no release is specified, verifies all releases that have packs.

        Options:
            --help              Show this help message.
            --asserts           Check assertion-enabled builds.
            --verbose           Show detailed diagnostic output.
            --fix               Delete packs that don't match expectations."""
end

function verify_main(args)
    args, opts = parse_args(args)
    for opt in keys(opts)
        if !in(opt, ["help", "asserts", "fix", "verbose"])
            println("Error: Unknown option '$opt'\n")
            println(verify_usage())
            return 1
        end
    end
    if haskey(opts, "help")
        println(verify_usage())
        return 0
    end
    asserts = haskey(opts, "asserts")
    fix = haskey(opts, "fix")
    verbose = haskey(opts, "verbose")

    versions = if isempty(args)
        # Find all versions that have packs
        discover_versions_with_packs(; asserts)
    else
        VersionNumber.(args)
    end

    if isempty(versions)
        println("No packs found to verify.")
        return 0
    end

    all_valid = true
    for (i, version) in enumerate(versions)
        if length(versions) > 1
            i > 1 && println()
            println("=== Julia $(version.major).$(version.minor) ===")
        end
        valid = verify_packs(version; asserts, fix, verbose)
        all_valid = all_valid && valid
    end

    return all_valid ? 0 : 1
end

function discover_versions_with_packs(; asserts::Bool)
    versions = VersionNumber[]
    branch_commits = julia_branch_commits()
    for version in sort(collect(keys(branch_commits)))
        db = "julia-$(version.major).$(version.minor)"
        if asserts
            db *= "-asserts"
        end
        db_list = list(db)
        if !isempty(db_list.packed)
            push!(versions, version)
        end
    end
    return versions
end

function verify_packs(version::VersionNumber; asserts::Bool, fix::Bool, verbose::Bool)
    db = "julia-$(version.major).$(version.minor)"
    if asserts
        db *= "-asserts"
    end

    db_list = list(db)
    if isempty(db_list.packed)
        println("No packs found for $db.")
        println()
        println("To build packs, run `manyjulias build $(version.major).$(version.minor)`.")
        return true
    end

    # Compute expected packs
    expected_packs = Dict{String,Vector{String}}()
    for (pack_name, commits) in julia_commit_packs(version)
        sname = safe_name("julia-$(pack_name)")
        expected_packs[sname] = collect(commits)
    end

    if verbose
        println("Expected $(length(expected_packs)) packs:")
        for (name, commits) in sort(collect(expected_packs); by=first)
            println("  $name: $(length(commits)) commits ($(first(commits)[1:7])..$(last(commits)[1:7]))")
        end
        println()
        println("Actual $(length(db_list.packed)) packs:")
        for (name, commits) in sort(collect(db_list.packed); by=first)
            println("  $name: $(length(commits)) commits ($(first(commits)[1:7])..$(last(commits)[1:7]))")
        end
        println()
    end

    packs_to_delete = String[]

    for (pack_name, actual_commits) in sort(collect(db_list.packed); by=first)
        if !haskey(expected_packs, pack_name)
            println("[INVALID] $pack_name: not in expected packs (boundaries shifted)")
            if verbose
                println("  Contains $(length(actual_commits)) commits:")
                for commit in actual_commits
                    println("    $commit")
                end
            end
            push!(packs_to_delete, pack_name)
            continue
        end

        expected = expected_packs[pack_name]
        expected_set = Set(expected)
        actual_set = Set(actual_commits)

        # Commits in pack that shouldn't be there
        unexpected = filter(c -> !(c in expected_set), actual_commits)
        # Commits expected but missing (OK if build failed)
        missing_commits = filter(c -> !(c in actual_set), expected)

        if !isempty(unexpected)
            println("[INVALID] $pack_name: $(length(unexpected)) unexpected commit(s)")
            for commit in unexpected
                # Try to find where this commit should be
                found_in = nothing
                for (other_pack, other_commits) in expected_packs
                    if commit in other_commits
                        found_in = other_pack
                        break
                    end
                end
                if found_in !== nothing
                    println("  $commit (should be in $found_in)")
                else
                    println("  $commit (not in any expected pack)")
                end
            end
            push!(packs_to_delete, pack_name)
        elseif verbose
            println("[OK] $pack_name: $(length(actual_commits))/$(length(expected)) commits")
            if !isempty(missing_commits)
                println("  Missing $(length(missing_commits)) commits (build failures?)")
            end
        end
    end

    # Check for expected packs that don't exist
    missing_packs = filter(p -> !haskey(db_list.packed, p), keys(expected_packs))
    if !isempty(missing_packs) && verbose
        println()
        println("Expected packs not yet created: $(length(missing_packs))")
        for pack_name in sort(collect(missing_packs))
            println("  $pack_name")
        end
    end

    println()
    if isempty(packs_to_delete)
        println("All $(length(db_list.packed)) packs are valid.")
        return true
    end

    println("$(length(packs_to_delete)) invalid pack(s) found.")

    if fix
        println()
        println("Deleting invalid packs...")
        for pack_name in packs_to_delete
            pack_path = joinpath(data_dir, db, "packs", pack_name)
            rm(pack_path * ".pack"; force=true)
            rm(pack_path * ".pack.idx"; force=true)
            println("  Deleted $pack_name")
        end
        println()
        println("Re-run `manyjulias build $(version.major).$(version.minor)` to recreate deleted packs.")
    else
        println()
        println("Run with --fix to delete invalid packs.")
    end

    return false
end
