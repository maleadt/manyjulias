# OCI sandbox abstraction

abstract type AbstractMount end
Base.@kwdef struct OverlayMount <: AbstractMount
    lower::String
    upper::String
    work::String
end
Base.@kwdef struct BindMount <: AbstractMount
    source::String
    writable::Bool
end

Base.@kwdef struct Sandbox
    name::String
    rootfs::String
    env::Dict{String,String}=Dict{String,String}()
    mounts::Array{Pair{String,AbstractMount}}=Pair{String,AbstractMount}[]
    cwd::String="/"
    uid::Int=0
    gid::Int=0
end

function build_oci_config(sandbox::Sandbox, cmd::Cmd; terminal::Bool)
    config = Dict()
    config["ociVersion"] = v"1.0.1"
    config["platform"] = (os="linux", arch="amd64")

    config["root"] = (; path=sandbox.rootfs, readonly=true)

    mounts = []
    for (destination, mount) in sandbox.mounts
        if mount isa BindMount
            # preserve mount options that restrict allowed operations, as not all container
            # runtimes do this for us (opencontainers/runc#1603, opencontainers/runc#1523).
            mount_options = filter(mount_info(mount.source).opts) do option
                option in ["nodev", "nosuid", "noexec"]
            end
            push!(mounts, (; destination, mount.source, type="none",
                             options=["bind", mount.writable ? "rw" : "ro", mount_options...]))
        elseif mount isa OverlayMount
            extra_options = [
                # needed for off-line access to the lower dir
                "xino=off",
                "metacopy=off",
                "index=off",
                "redirect_dir=nofollow"
            ]
            if get_kernel_version() >= v"5.11-"
                # needed for unprivileged use
                push!(extra_options, "userxattr")
            end
            push!(mounts, (; destination, type="overlay",
                             options=["lowerdir=$(mount.lower)",
                                      "upperdir=$(mount.upper)",
                                      "workdir=$(mount.work)",
                                      extra_options...]))
        else
            error("Unknown mount type: $(typeof(mount))")
        end
    end
    ## Linux stuff
    push!(mounts, (destination="/proc", type="proc", source="proc"))
    push!(mounts, (destination="/dev", type="tmpfs", source="tmpfs",
                   options=["nosuid", "strictatime", "mode=755", "size=65536k"]))
    push!(mounts, (destination="/dev/pts", type="devpts", source="devpts",
                   options=["nosuid", "noexec", "newinstance",
                            "ptmxmode=0666", "mode=0620"]))
    push!(mounts, (destination="/dev/shm", type="tmpfs", source="shm",
                   options=["nosuid", "noexec", "nodev", "mode=1777", "size=65536k"]))
    push!(mounts, (destination="/dev/mqueue", type="mqueue", source="mqueue",
                   options=["nosuid", "noexec", "nodev"]))
    push!(mounts, (destination="/sys", type="none", source="/sys",
                   options=["rbind", "nosuid", "noexec", "nodev", "ro"]))
    push!(mounts, (destination="/sys/fs/cgroup", type="cgroup", source="cgroup",
                   options=["nosuid", "noexec", "nodev", "relatime", "ro"]))
    config["mounts"] = mounts

    process = Dict()
    process["terminal"] = terminal
    cmd′ = setenv(cmd, sandbox.env)
    if cmd.env !== nothing
        cmd′ = addenv(cmd, cmd.env; inherit=false)
    end
    process["env"] = cmd′.env
    process["args"] = cmd′.exec
    process["cwd"] = isempty(cmd.dir) ? sandbox.cwd : cmd.dir
    process["user"] = (; sandbox.uid, sandbox.gid)
    ## POSIX stuff
    process["rlimits"] = [
        (type="RLIMIT_NOFILE", hard=8192, soft=8192),
    ]
    ## Linux stuff
    process["capabilities"] = (
        bounding = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
        permitted = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
        inheritable = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
        effective = ["CAP_AUDIT_WRITE", "CAP_KILL"],
        ambient = ["CAP_NET_BIND_SERVICE"],
    )
    process["noNewPrivileges"] = true
    config["process"] = process

    config["hostname"] = sandbox.name

    # Linux platform configuration
    # https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md
    linux = Dict()
    linux["namespaces"] = [
        (type="pid",),
        (type="ipc",),
        (type="uts",),
        (type="mount",),
        (type="user",),
    ]
    linux["uidMappings"] = [
        (hostID=getuid(), containerID=sandbox.uid, size=1),
    ]
    linux["gidMappings"] = [
        (hostID=getgid(), containerID=sandbox.gid, size=1),
    ]
    config["linux"] = linux

    return config
end

abs2rel(path) = path[1] == '/' ? path[2:end] : path

function sandbox(cmd; workdir::String,
                      rootfs::String=artifact"debian_minimal",
                      name::String=randstring(),
                      mounts::Dict{String,String}=Dict{String,String}(),
                      env::Dict{String,String}=Dict{String,String}(),
                      uid::Int=0, gid::Int=0, cwd::String="/",
                      terminal::Bool=false)
    # make sure certain common directories are writable
    mounts = [
        "/tmp"          => joinpath(rootfs, "tmp"),
        "/var"          => joinpath(rootfs, "var"),
        "/home"         => joinpath(rootfs, "home"),
        "/root"         => joinpath(rootfs, "root"),
        "/usr/local"    => joinpath(rootfs, "usr/local"),
        mounts...]

    # convert the human-readable mount specs to mount objects
    sandbox_mounts = Pair{String,AbstractMount}[]
    for (destination, source) in mounts
        # if explicitly :ro or :rw, just bind mount
        if endswith(destination, ":ro")
            push!(sandbox_mounts, destination[begin:end-3] => BindMount(; source, writable=false))
        elseif endswith(destination, ":rw")
            push!(sandbox_mounts, destination[begin:end-3] => BindMount(; source, writable=true))
        # in other cases, use overlays so that we can write without changing the host
        else
            lower = source
            upper = joinpath(workdir, "upper", abs2rel(destination))
            work = joinpath(workdir, "work", abs2rel(destination))
            mkpath(upper)
            mkpath(work)
            push!(sandbox_mounts, destination => OverlayMount(; lower, upper, work))
        end
    end

    # create a sandbox configuration
    sandbox = Sandbox(;  name, rootfs, mounts=sandbox_mounts, env, uid, gid, cwd)
    sandbox_config = build_oci_config(sandbox, cmd; terminal)

    # write the configuration to a bundle
    bundle_path = joinpath(workdir, "bundle")
    mkpath(bundle_path)
    config_path = joinpath(bundle_path, "config.json")
    open(config_path, "w") do io
        JSON3.write(io, sandbox_config)
    end

    `$(crun()) --root $(sandbox_dir) run --bundle $bundle_path $(sandbox.name)`
end
