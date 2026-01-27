# CLI framework for manyjulias

include("commands/run.jl")
include("commands/status.jl")
include("commands/build.jl")
include("commands/verify.jl")

# Command registry
const COMMANDS = Dict{String,NamedTuple{(:desc, :usage, :main), Tuple{String, Function, Function}}}(
    "run"    => (desc=RUN_COMMAND_DESC,    usage=run_usage,    main=run_main),
    "build"  => (desc=BUILD_COMMAND_DESC,  usage=build_usage,  main=build_main),
    "verify" => (desc=VERIFY_COMMAND_DESC, usage=verify_usage, main=verify_main),
    "status" => (desc=STATUS_COMMAND_DESC, usage=status_usage, main=status_main),
)

function show_help()
    println("""
        Usage: manyjulias <command> [args...]

        Commands:
          [run] <ref> [args...]  $(COMMANDS["run"].desc)
          build [release]        $(COMMANDS["build"].desc)
          verify [release]       $(COMMANDS["verify"].desc)
          status [release]       $(COMMANDS["status"].desc)

        Run 'manyjulias <command> --help' for command-specific help.""")
end

"""
    determine_command(args) -> (command_name, remaining_args)

Determine which command to run based on args:
1. If first arg is a known command name -> use it
2. If first arg starts with `-` -> implicit "run" with all args
3. Otherwise -> implicit "run", first arg is git ref
"""
function determine_command(args)
    if isempty(args)
        return (nothing, String[])
    end

    first_arg = args[1]

    # Check for help flags at top level
    if first_arg in ["--help", "-h", "-help"]
        return ("help", String[])
    end

    # If first arg is a known command, use it
    if haskey(COMMANDS, first_arg)
        return (first_arg, args[2:end])
    end

    # Otherwise, implicit "run" command
    return ("run", args)
end

"""
    cli_main(args) -> Int

Main entry point for the CLI. Returns exit code.
"""
function cli_main(args)
    command, remaining = determine_command(args)

    if command === nothing || command == "help"
        show_help()
        return 0
    end

    if !haskey(COMMANDS, command)
        println("Error: Unknown command '$command'\n")
        show_help()
        return 1
    end

    return COMMANDS[command].main(remaining)
end

function parse_args(args)
    opts = Dict{String,Union{String,Missing}}()
    positional = String[]
    for arg in args
        if startswith(arg, "--")
            if contains(arg, "=")
                key, val = split(arg, "="; limit=2)
                opts[key[3:end]] = val
            else
                opts[arg[3:end]] = missing
            end
        elseif startswith(arg, "-") && length(arg) > 1
            # Short option: -j4 -> opts["j"] = "4", -v -> opts["v"] = missing
            key = string(arg[2])
            opts[key] = length(arg) > 2 ? arg[3:end] : missing
        else
            push!(positional, arg)
        end
    end

    return positional, opts
end
