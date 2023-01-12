function safe_name(name)
    # Only latin letters, digits, -, _ and / are allowed
    return replace(name, r"[^a-zA-Z0-9\-_\/]" => "_")
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
