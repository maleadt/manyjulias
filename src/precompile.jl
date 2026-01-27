using PrecompileTools

# Precompile common code paths to reduce first-run compilation overhead
success(`which git`) && @setup_workload begin
    global sandbox_dir = mktempdir()
    global data_dir = mktempdir()
    global download_dir = mktempdir()

    # Create a minimal git repo with VERSION file
    src_repo = joinpath(download_dir, "src")
    mkpath(src_repo)
    run(`git -C $src_repo init -q`)
    write(joinpath(src_repo, "VERSION"), "1.14.0-DEV\n")
    run(`git -C $src_repo add VERSION`)
    run(`git -C $src_repo -c user.email=x -c user.name=x commit -q -m Initial`)

    # Clone as bare repo to expected location
    bare_repo = joinpath(download_dir, "julia")
    run(`git clone -q --bare $src_repo $bare_repo`)
    touch(joinpath(bare_repo, "FETCH_HEAD"))

    # Create a dummy Julia "build" with a shell script
    build_dir = mktempdir()
    mkpath(joinpath(build_dir, "bin"))
    write(joinpath(build_dir, "bin", "julia"), """
        #!/bin/sh
        exit 0
        """)
    chmod(joinpath(build_dir, "bin", "julia"), 0o755)

    @compile_workload begin
        commit = julia_lookup("HEAD")

        # Store the dummy build (exercises prepare + elfshaker store)
        store!("julia-1.14", commit, build_dir)

        # Full CLI run exercises: parse_args, list, extract_readonly!, sandbox
        cli_main(["run", "HEAD"])

        invalidate_repo_handle!()
    end
end
