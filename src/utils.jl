function safe_name(name)
    # Only latin letters, digits, -, _ and / are allowed
    return replace(name, r"[^a-zA-Z0-9\-_\/]" => "_")
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


# list the children of a process.
# note that this may return processes that have already exited, so beware of TOCTOU.
function process_children(pid)
    tids = try
        readdir("/proc/$pid/task")
    catch err # TOCTOU
        if (isa(err, SystemError)  && err.errnum in [Libc.ENOENT, Libc.ESRCH]) ||
           (isa(err, Base.IOError) && err.code in [Base.UV_ENOENT, Base.UV_ESRCH])
            # the process has already exited
            return Int[]
        else
            rethrow()
        end
    end

    pids = Int[]
    for tid in tids
        try
            children = read("/proc/$pid/task/$tid/children", String)
            append!(pids, parse.(Int, split(children)))
        catch err # TOCTOU
            if (isa(err, SystemError)  && err.errnum in [Libc.ENOENT, Libc.ESRCH]) ||
               (isa(err, Base.IOError) && err.code in [Base.UV_ENOENT, Base.UV_ESRCH])
                # the task has already exited
            else
                rethrow()
            end
        end
    end
    return pids
end


# kill a process and all of its children
function recursive_kill(proc, sig)
    parent_pid = try
        getpid(proc)
    catch err # TOCTOU
        if (isa(err, SystemError)  && err.errnum == Libc.ESRCH) ||
           (isa(err, Base.IOError) && err.code == Base.UV_ESRCH)
            # the process has already exited
            return
        else
            rethrow(err)
        end
    end
    for pid in reverse([parent_pid; process_children(parent_pid)])
        ccall(:uv_kill, Cint, (Cint, Cint), pid, sig)
    end
    return
end

getuid() = ccall(:getuid, Cint, ())
getgid() = ccall(:getgid, Cint, ())

struct mntent
    fsname::Cstring # name of mounted filesystem
    dir::Cstring    # filesystem path prefix
    type::Cstring   # mount type (see mntent.h)
    opts::Cstring   # mount options (see mntent.h)
    freq::Cint      # dump frequency in days
    passno::Cint    # pass number on parallel fsck
end

function mount_info(path::String)
    found = nothing
    path_stat = stat(path)

    stream = ccall(:setmntent, Ptr{Nothing}, (Cstring, Cstring), "/etc/mtab", "r")
    while true
        # get the next mtab entry
        entry = ccall(:getmntent, Ptr{mntent}, (Ptr{Nothing},), stream)
        entry == C_NULL && break

        # convert it to something usable
        entry = unsafe_load(entry)
        entry = (;
            fsname  = unsafe_string(entry.fsname),
            dir     = unsafe_string(entry.dir),
            type    = unsafe_string(entry.type),
            opts    = split(unsafe_string(entry.opts), ","),
            entry.freq,
            entry.passno,
        )

        mnt_stat = try
            stat(entry.dir)
        catch
            continue
        end

        if mnt_stat.device == path_stat.device
            found = entry
            break
        end
    end
    ccall(:endmntent, Cint, (Ptr{Nothing},), stream)

    return found
end


# A version of `chmod()` that hides all of its errors.
function chmod_recursive(root::String, perms)
    files = String[]
    try
        files = readdir(root)
    catch e
        if !isa(e, Base.IOError)
            rethrow(e)
        end
    end
    for f in files
        path = joinpath(root, f)
        try
            chmod(path, perms)
        catch e
            if !isa(e, Base.IOError)
                rethrow(e)
            end
        end
        if isdir(path) && !islink(path)
            chmod_recursive(path, perms)
        end
    end
end


const kernel_version = Ref{Union{VersionNumber,Missing}}()
function get_kernel_version()
    if !isassigned(kernel_version)
        kver_str = strip(read(`/bin/uname -r`, String))
        kver = parse_kernel_version(kver_str)
        kernel_version[] = something(kver, missing)
    end
    return kernel_version[]
end
function parse_kernel_version(kver_str::AbstractString)
    kver = tryparse(VersionNumber, kver_str)
    if kver isa VersionNumber
        return kver
    end

    # Regex for RHEL derivatives:
    # https://github.com/JuliaCI/PkgEval.jl/pull/287
    r = r"^(\d*?\.\d*?\.\d*?)-[\w\d._]*?$"
    m = match(r, kver_str)
    if m isa RegexMatch
        kver = tryparse(VersionNumber, m[1])
        if kver isa VersionNumber
            return kver
        end
    end

    @warn "Failed to parse kernel version '$kver_str'"
    return nothing
end
