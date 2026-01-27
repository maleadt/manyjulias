# Run command - launch Julia from a specific revision

const RUN_COMMAND_NAME = "run"
const RUN_COMMAND_DESC = "Launch Julia from a revision (default if no command)"

function run_usage()
    return """
        Usage: manyjulias run [options] <ref> [julia args...]
               manyjulias <ref> [julia args...]

        Launch Julia from a given revision, if available in a pack.

        The revision can be specified as a commit SHA, branch or tag name, etc.
        Any remaining arguments are passed to the launched Julia process.

        Options:
            --help              Show this help message.
            --asserts           Use builds with assertions enabled."""
end

function run_main(all_args)
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

    args, opts = parse_args(args)
    for opt in keys(opts)
        if !in(opt, ["help", "asserts"])
            println("Error: Unknown option '$opt'\n")
            println(run_usage())
            return 1
        end
    end
    asserts = haskey(opts, "asserts")
    if haskey(opts, "help")
        println(run_usage())
        return 0
    end

    # determine the commit and its release version
    if isempty(args)
        println("Error: Missing revision argument\n")
        println(run_usage())
        return 1
    elseif length(args) > 1
        println("Error: Too many arguments\n")
        println(run_usage())
        return 1
    end
    rev = args[1]
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

    return run_launch(commit, child_args; db)
end

function run_launch(commit, child_args; db)
    # extract to a temp dir
    dir = mktempdir()
    extract_readonly!(db, commit, dir)
    julia_path = joinpath(dir, "bin", "julia")
    @assert isfile(julia_path)

    # launch a monitor to clean up after we execve
    parent_pid = getpid()
    monitor_code = """
        try
            pid = parse(Int, ARGS[1])
            dirs = ARGS[2:end]

            while ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == 0
                sleep(0.1)
            end

            for d in dirs
                rm(d; recursive=true, force=true)
            end
        catch e
            @error "Monitor error" exception=(e, catch_backtrace())
        end
    """
    monitor_cmd = detach(`$(Base.julia_cmd()) --startup-file=no -e $monitor_code -- $parent_pid $dir $sandbox_dir`)

    if ccall(:jl_generating_output, Cint, ()) == 0
        run(monitor_cmd; wait=false)
        execv(julia_path, child_args)
    end
end
