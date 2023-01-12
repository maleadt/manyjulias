function safe_name(name)
    # Only latin letters, digits, -, _ and / are allowed
    return replace(name, r"[^a-zA-Z0-9\-_\/]" => "_")
end

function parse_args(args)
    opts = Dict{String,Union{String,Missing}}()
    for arg in args
        if startswith(arg, "--")
            if contains(arg, "=")
                key, val = split(arg, "="; limit=2)
                opts[key[3:end]] = val
            else
                opts[arg[3:end]] = missing
            end
        end
    end

    args = filter(args) do arg
        !startswith(arg, "--")
    end

    return args, opts
end
