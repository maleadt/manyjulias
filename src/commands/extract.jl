# Extract command - copy a Julia build to a directory

const EXTRACT_COMMAND_NAME = "extract"
const EXTRACT_COMMAND_DESC = "Extract a Julia build to a directory"

function extract_usage()
    return """
        Usage: manyjulias extract [options] <ref> <target-dir>

        Extract a Julia build from a given revision to a target directory.

        The revision can be specified as a commit SHA, branch or tag name, etc.
        The target directory will be created if it doesn't exist.

        Options:
            --help              Show this help message.
            --asserts           Use builds with assertions enabled."""
end

function extract_main(args)
    args, opts = parse_args(args)
    for opt in keys(opts)
        if !in(opt, ["help", "asserts"])
            println("Error: Unknown option '$opt'\n")
            println(extract_usage())
            return 1
        end
    end
    asserts = haskey(opts, "asserts")
    if haskey(opts, "help")
        println(extract_usage())
        return 0
    end

    # require exactly 2 positional args
    if length(args) < 2
        println("Error: Missing arguments (need <ref> and <target-dir>)\n")
        println(extract_usage())
        return 1
    elseif length(args) > 2
        println("Error: Too many arguments\n")
        println(extract_usage())
        return 1
    end
    rev = args[1]
    target_dir = args[2]

    # determine the commit and its release version
    commit = julia_lookup(rev)
    if rev != commit
        @debug "Translated requested revision $rev to commit $commit"
    end
    version = julia_commit_version(commit)
    db = "julia-$(version.major).$(version.minor)"
    if asserts
        db *= "-asserts"
    end

    # check if we have this commit
    available_commits = Set(union(list(db).loose, values(list(db).packed)...))
    if commit ∉ available_commits
        @error("Commit $commit is not available in any pack. Run `manyjulias build $(version.major).$(version.minor)` to generate it.")
        return 125
    end

    # extract to the target directory
    mkpath(target_dir)
    extract_readonly!(db, commit, target_dir)

    println("Extracted Julia $commit to $target_dir")
    return 0
end
