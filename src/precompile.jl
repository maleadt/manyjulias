using PrecompileTools

# Precompile common code paths to reduce first-run compilation overhead
@setup_workload begin
    @compile_workload begin
        # Precompile argument parsing
        try
            parse_args(["--help"])
        catch
        end

        # Precompile sandbox configuration (without actually running anything)
        try
            # Create minimal sandbox command configuration with realistic mounts
            workdir_tmp = mktempdir()
            rootfs_tmp = mktempdir()
            try
                # This mimics the actual call in extract_readonly!
                sandbox(`/bin/echo test`;
                        workdir=workdir_tmp,
                        uid=1000, gid=1000,
                        cwd="/target_dir",
                        mounts=Dict(
                            "/test1:ro" => "/tmp",
                            "/test2" => "/tmp",
                            "/test3:rw" => "/tmp"))
            catch
            end
            rm(workdir_tmp; recursive=true, force=true)
            rm(rootfs_tmp; recursive=true, force=true)
        catch
        end

        # Precompile elfshaker list operation
        try
            list("julia-1.11")
        catch
        end

        # Precompile julia_lookup git operations
        try
            if ispath(joinpath(download_dir, "julia", "config"))
                julia_verify("HEAD")
                # Also precompile the actual lookup path
                julia_lookup("HEAD")
                julia_commit_version(julia_lookup("HEAD"))
            end
        catch
        end
    end
end
