
const julia_updated = Ref(false)
const julia_lock = ReentrantLock()

# get an updated Julia (mirror) repository
function julia_repo()
    dir = joinpath(download_dir, "julia")
    if !ispath(joinpath(dir, "config")) || !julia_updated[]
        lock(julia_lock) do
            if !ispath(joinpath(dir, "config"))
                @info "Cloning Julia repository..."
                run(`$(git()) clone --mirror --quiet https://github.com/JuliaLang/julia $dir`)
            elseif !julia_updated[]
                @info "Updating Julia repository..."
                run(`$(git()) -C $dir fetch --quiet --force origin`)
            end
        end
    end
    julia_updated[] = true

    return dir
end

# check-out a specific Julia commit
function julia_checkout!(commit, dir)
    julia = julia_repo()

    # check-out the commit
    mkpath(dir)
    run(`$(git()) clone --quiet $julia $dir`)
    run(`$(git()) -C $dir reset --quiet --hard $commit`)
    return dir
end
julia_checkout(commit) = julia_checkout!(commit, mktempdir())

# populate Julia's srccache
function populate_srccache!(source_dir)
    srccache = joinpath(download_dir, "srccache")
    mkpath(srccache)

    repo_srccache = joinpath(source_dir, "deps", "srccache")
    cp(srccache, repo_srccache)
    run(ignorestatus(setenv(`make -C deps getall NO_GIT=1`; dir=source_dir)),
        devnull, devnull, devnull)
    for file in readdir(repo_srccache)
        if !ispath(joinpath(srccache, file))
            cp(joinpath(repo_srccache, file), joinpath(srccache, file))
        end
    end
end

# Julia version of contrib/commit-name.sh
function commit_name(julia, commit)
    version = readchomp(`$(git()) -C $julia show $commit:VERSION`)
    endswith(version, "-DEV") || error("Only commits from the master branch are supported")

    branch_commit = let
        blame = readchomp(`$(git()) -C $julia blame -L ,1 -sl $commit -- VERSION`)
        split(blame)[1]
    end

    commits = let
        count = readchomp(`$(git()) -C $julia rev-list --count $commit "^$branch_commit"`)
        parse(Int, count)
    end

    return "$version.$(commits)"

    return (; version, commits)
end
