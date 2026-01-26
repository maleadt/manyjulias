# LibGit2 worktree extensions for manyjulias
#
# NOTE: These functions wrap libgit2 worktree operations not yet available in
# Julia's stdlib LibGit2. They should be upstreamed to Julia's LibGit2 stdlib.
# See: https://github.com/JuliaLang/julia

using LibGit2_jll: libgit2

# Worktree type following LibGit2 stdlib patterns
mutable struct GitWorktree <: LibGit2.AbstractGitObject
    owner::LibGit2.GitRepo
    ptr::Ptr{Cvoid}
    function GitWorktree(owner::LibGit2.GitRepo, ptr::Ptr{Cvoid})
        @assert ptr != C_NULL
        obj = new(owner, ptr)
        finalizer(Base.close, obj)
        return obj
    end
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, wt::GitWorktree) = wt.ptr

function Base.close(wt::GitWorktree)
    if wt.ptr != C_NULL
        ccall((:git_worktree_free, libgit2), Cvoid, (Ptr{Cvoid},), wt.ptr)
        wt.ptr = C_NULL
    end
end

# Error checking macro (matching LibGit2 pattern)
macro wt_check(expr)
    quote
        err = Cint($(esc(expr)))
        if err < 0
            throw(LibGit2.GitError(err))
        end
        err
    end
end

# Helper function: set HEAD to a detached state at a specific commit
# (not available in Julia's stdlib LibGit2)
function set_head_detached!(repo::LibGit2.GitRepo, oid::LibGit2.GitHash)
    @wt_check ccall((:git_repository_set_head_detached, libgit2), Cint,
                    (Ptr{Cvoid}, Ptr{LibGit2.GitHash}),
                    repo, Ref(oid))
    return nothing
end

"""
    worktree_list(repo::GitRepo) -> Vector{String}

List all worktree names in the repository.
"""
function worktree_list(repo::LibGit2.GitRepo)
    sa_ref = Ref(LibGit2.StrArrayStruct())
    @wt_check ccall((:git_worktree_list, libgit2), Cint,
                    (Ptr{LibGit2.StrArrayStruct}, Ptr{Cvoid}),
                    sa_ref, repo)
    sa = sa_ref[]
    result = [unsafe_string(unsafe_load(sa.strings, i)) for i in 1:sa.count]
    ccall((:git_strarray_dispose, libgit2), Cvoid, (Ptr{LibGit2.StrArrayStruct},), sa_ref)
    return result
end

"""
    worktree_lookup(repo::GitRepo, name::AbstractString) -> GitWorktree

Lookup a worktree by name. Returns a GitWorktree handle.
"""
function worktree_lookup(repo::LibGit2.GitRepo, name::AbstractString)
    wt_ptr_ref = Ref{Ptr{Cvoid}}(C_NULL)
    @wt_check ccall((:git_worktree_lookup, libgit2), Cint,
                    (Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Cstring),
                    wt_ptr_ref, repo, name)
    return GitWorktree(repo, wt_ptr_ref[])
end

"""
    worktree_validate(wt::GitWorktree) -> Bool

Check if a worktree is valid. Returns true if valid, false otherwise.
"""
function worktree_validate(wt::GitWorktree)
    err = ccall((:git_worktree_validate, libgit2), Cint, (Ptr{Cvoid},), wt)
    return err == 0
end

# Worktree add options structure
struct GitWorktreeAddOptions
    version::Cuint
    lock::Cint        # bool: lock the worktree after creation
    ref::Ptr{Cvoid}   # git_reference*: reference to use for HEAD (NULL for detached)
    checkout_options::LibGit2.CheckoutOptions
end

function GitWorktreeAddOptions(; lock::Bool=false, ref::Ptr{Cvoid}=C_NULL)
    GitWorktreeAddOptions(
        1,  # GIT_WORKTREE_ADD_OPTIONS_VERSION
        lock ? 1 : 0,
        ref,
        LibGit2.CheckoutOptions()
    )
end

"""
    worktree_add!(repo::GitRepo, name::AbstractString, path::AbstractString,
                  commit::AbstractString) -> GitWorktree

Add a worktree at the specified path with a detached HEAD at the given commit.
This is equivalent to `git worktree add --detach <path> <commit>`.

## libgit2 Limitation and Workaround

libgit2's `git_worktree_add` does not directly support creating worktrees with a
detached HEAD (unlike `git worktree add --detach`). Two issues arise:

1. **ref=NULL uses repo HEAD**: When `opts.ref` is NULL, libgit2 uses the repo's
   current HEAD. For bare repos (like our Julia mirror), HEAD may point to a
   non-existent branch (e.g., "refs/heads/main"), causing the operation to fail.

2. **Branch reference required**: `git_worktree_add` requires `opts.ref` to be a
   branch reference. Passing a plain commit reference fails with "reference is
   not a branch".

**Workaround**: We create a temporary branch at the target commit, use it to
create the worktree, then detach HEAD and delete the temporary branch:

1. Create temporary branch "worktree-temp-\$name" at target commit
2. Create worktree using the temporary branch as `opts.ref`
3. Open worktree repo and call `git_repository_set_head_detached` to detach HEAD
4. Delete the temporary branch from the main repo

This achieves the same end result as `git worktree add --detach`.
"""
function worktree_add!(repo::LibGit2.GitRepo, name::AbstractString,
                       path::AbstractString, commit::AbstractString)
    # Resolve the commit to a GitCommit
    obj = LibGit2.GitObject(repo, commit)
    commit_obj = LibGit2.peel(LibGit2.GitCommit, obj)
    commit_hash = LibGit2.GitHash(commit_obj)

    # WORKAROUND: git_worktree_add requires a branch reference, not a commit.
    # Create a temporary branch at the target commit.
    temp_branch_name = "worktree-temp-$name"
    branch_ref = LibGit2.create_branch(repo, temp_branch_name, commit_obj; force=true)

    wt_ptr_ref = Ref{Ptr{Cvoid}}(C_NULL)
    opts = GitWorktreeAddOptions(; lock=false, ref=branch_ref.ptr)

    try
        @wt_check ccall((:git_worktree_add, libgit2), Cint,
                        (Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Cstring, Cstring, Ptr{GitWorktreeAddOptions}),
                        wt_ptr_ref, repo, name, path, Ref(opts))
    finally
        close(branch_ref)
    end

    wt = GitWorktree(repo, wt_ptr_ref[])

    # WORKAROUND continued: The worktree was created with HEAD pointing to the
    # temp branch. Set it to detached HEAD at the commit.
    wt_repo = LibGit2.GitRepo(path)
    try
        set_head_detached!(wt_repo, commit_hash)
    finally
        close(wt_repo)
    end

    # WORKAROUND continued: Delete the temporary branch from the main repo.
    branch_ref = LibGit2.lookup_branch(repo, temp_branch_name)
    if branch_ref !== nothing
        LibGit2.delete_branch(branch_ref)
        close(branch_ref)
    end

    return wt
end

# Worktree prune options structure
struct GitWorktreePruneOptions
    version::Cuint
    flags::Cuint
end

# Prune flags
const GIT_WORKTREE_PRUNE_VALID = Cuint(1 << 0)
const GIT_WORKTREE_PRUNE_LOCKED = Cuint(1 << 1)
const GIT_WORKTREE_PRUNE_WORKING_TREE = Cuint(1 << 2)

function GitWorktreePruneOptions(; valid::Bool=false, locked::Bool=false, working_tree::Bool=false)
    flags = Cuint(0)
    valid && (flags |= GIT_WORKTREE_PRUNE_VALID)
    locked && (flags |= GIT_WORKTREE_PRUNE_LOCKED)
    working_tree && (flags |= GIT_WORKTREE_PRUNE_WORKING_TREE)
    GitWorktreePruneOptions(1, flags)  # GIT_WORKTREE_PRUNE_OPTIONS_VERSION = 1
end

"""
    worktree_prune!(wt::GitWorktree; valid::Bool=false, locked::Bool=false,
                    working_tree::Bool=false)

Prune a worktree, removing its administrative files. By default only prunes
worktrees that are no longer valid (directory deleted). Set flags to force
pruning of valid, locked, or worktrees with existing working trees.
"""
function worktree_prune!(wt::GitWorktree; valid::Bool=false, locked::Bool=false,
                         working_tree::Bool=false)
    opts = GitWorktreePruneOptions(; valid, locked, working_tree)
    @wt_check ccall((:git_worktree_prune, libgit2), Cint,
                    (Ptr{Cvoid}, Ptr{GitWorktreePruneOptions}),
                    wt, Ref(opts))
    return nothing
end

"""
    worktree_prune_stale!(repo::GitRepo)

Prune all stale/invalid worktrees in the repository.
This is equivalent to `git worktree prune`.
"""
function worktree_prune_stale!(repo::LibGit2.GitRepo)
    for name in worktree_list(repo)
        wt = worktree_lookup(repo, name)
        try
            if !worktree_validate(wt)
                worktree_prune!(wt)
            end
        finally
            close(wt)
        end
    end
    return nothing
end
