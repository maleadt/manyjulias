# Extensions to the LibGit2 stdlib

import LibGit2
import LibGit2_jll: libgit2

"""
    LibGit2.head!(repo::GitRepo, oid::GitHash) -> GitHash

Set the HEAD of `repo` to point directly at `oid`, detaching from any branch.
This is equivalent to `git checkout --detach <oid>` (without modifying the working tree).
"""
function LibGit2.head!(repo::LibGit2.GitRepo, oid::LibGit2.GitHash)
    LibGit2.ensure_initialized()
    err = ccall((:git_repository_set_head_detached, libgit2), Cint,
                (Ptr{Cvoid}, Ref{LibGit2.GitHash}), repo, oid)
    if err < 0
        throw(LibGit2.Error.GitError(err))
    end
    return oid
end
